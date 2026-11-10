use std::collections::BTreeSet;

use super::*;
use crate::api::docker::DockerComposeAction;

const COMPOSE_TIMEOUT: &str = "编排操作超时，部分服务可能已变更，请刷新列表检查";
const COMPOSE_PERMISSION: &str = "没有权限操作 Docker 编排";
const METADATA: &str = "编排信息不完整或已变化，请刷新后重试";
const SOURCE: &str = "无法找到编排的原配置文件，请检查配置路径和读取权限";

#[derive(Clone, Debug, PartialEq, Eq)]
struct SourceFiles {
    directory: String,
    configs: Vec<String>,
    environment: Vec<String>,
}

struct Project {
    name: String,
    containers: BTreeSet<String>,
    images: BTreeSet<String>,
    services: BTreeSet<String>,
    source: Option<SourceFiles>,
}

fn label<'a>(container: &'a Value, key: &str) -> &'a str {
    container["Labels"][format!("com.docker.compose.{key}")]
        .as_str()
        .unwrap_or("")
}

fn path(value: &str, directory: &str) -> Result<String> {
    ensure!(
        !value.is_empty() && value.len() <= 4096 && !value.chars().any(char::is_control),
        "{SOURCE}"
    );
    Ok(if value.starts_with('/') {
        value.to_owned()
    } else {
        format!("{directory}/{value}")
    })
}

fn source_files(container: &Value) -> Result<SourceFiles> {
    let directory = label(container, "project.working_dir");
    ensure!(directory.starts_with('/'), "{SOURCE}");
    let directory = path(directory, "")?;
    let files = |key: &str| -> Result<Vec<String>> {
        let value = label(container, key);
        if value.is_empty() {
            return Ok(Vec::new());
        }
        let paths = value
            .split(',')
            .map(|p| path(p, &directory))
            .collect::<Result<Vec<_>>>()?;
        ensure!(paths.len() <= 64, "{SOURCE}");
        Ok(paths)
    };
    let configs = files("project.config_files")?;
    ensure!(!configs.is_empty(), "{SOURCE}");
    let environment = files("project.environment_file")?;
    Ok(SourceFiles {
        directory,
        configs,
        environment,
    })
}

fn project_from_json(name: &str, data: &Value, rebuilding: bool) -> Result<Project> {
    let containers = data.as_array().ok_or_else(|| anyhow!(METADATA))?;
    ensure!(
        !containers.is_empty(),
        "Docker 资源可能已移除，请刷新后重试"
    );
    ensure!(containers.len() <= 10000, "编排资源过多，无法执行此操作");
    let mut project = Project {
        name: name.into(),
        containers: BTreeSet::new(),
        images: BTreeSet::new(),
        services: BTreeSet::new(),
        source: None,
    };
    for container in containers {
        ensure!(label(container, "project") == name, "{METADATA}");
        let id = container["Id"].as_str().ok_or_else(|| anyhow!(METADATA))?;
        validate_docker_id(DockerResourceKind::Container, id)?;
        project.containers.insert(id.into());
        if rebuilding {
            let image = container["ImageID"]
                .as_str()
                .ok_or_else(|| anyhow!(METADATA))?;
            validate_docker_id(DockerResourceKind::Image, image)?;
            project.images.insert(image.into());
        }
        if label(container, "oneoff").eq_ignore_ascii_case("true") {
            continue;
        }
        let service = label(container, "service");
        ensure!(
            !service.is_empty()
                && service.len() <= 255
                && !service.starts_with('-')
                && service
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b)),
            "{METADATA}"
        );
        project.services.insert(service.into());
        if rebuilding {
            let source = source_files(container)?;
            ensure!(
                project.source.as_ref().is_none_or(|old| *old == source),
                "编排服务的配置来源不一致，请检查原配置后重试"
            );
            project.source = Some(source);
        }
    }
    ensure!(!project.services.is_empty(), "{METADATA}");
    Ok(project)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Check,
    Start,
    Stop,
    Down,
    Rebuild,
}

trait ComposeEngine: Engine {
    fn compose(&self, project: &Project, phase: Phase) -> impl Future<Output = Result<()>> + Send;
}

fn compose_command(access: &Access, project: &Project, phase: Phase) -> Result<String> {
    let rebuilding = matches!(phase, Phase::Check | Phase::Rebuild);
    let mut options = format!("--project-name {}", shell_argument(&project.name));
    if rebuilding {
        let source = project.source.as_ref().ok_or_else(|| anyhow!(SOURCE))?;
        options.push_str(&format!(
            " --project-directory {} --profile '*'",
            shell_argument(&source.directory)
        ));
        for file in &source.configs {
            options.push_str(&format!(" --file {}", shell_argument(file)));
        }
        for file in &source.environment {
            options.push_str(&format!(" --env-file {}", shell_argument(file)));
        }
    }
    let services = project
        .services
        .iter()
        .map(|s| shell_argument(s))
        .collect::<Vec<_>>()
        .join(" ");
    let steps = match phase {
        Phase::Check => {
            let checks = project.services.iter().map(|s| format!(
                "grep -F -x -q -- {} \"$compose_temp/output\" || exit 83", shell_argument(s)
            )).collect::<Vec<_>>().join("\n");
            format!("run 82 config --services\n{checks}")
        }
        Phase::Start => "run 87 start".into(),
        Phase::Stop => "run 88 stop --timeout 20".into(),
        Phase::Down => "run 89 down --remove-orphans --timeout 20".into(),
        Phase::Rebuild => format!(
            "run 84 pull --ignore-buildable --include-deps {services}\nrun 85 build --with-dependencies --no-cache --pull {services}\nrun 86 up --detach --no-build --pull never {services}"
        ),
    };
    // Substitute complete template lines once; paths containing placeholder text stay literal.
    let script = include_str!("api/docker_compose_exec.sh")
        .lines()
        .map(|line| match line {
            "@COMPOSE_COMMAND@" => {
                format!("{} compose --ansi never {options} \"$@\"", access.cli())
            }
            "@COMPOSE_STEPS@" => steps.clone(),
            _ => line.to_owned(),
        })
        .collect::<Vec<_>>()
        .join("\n");
    Ok(server_status_command(&script))
}

impl ComposeEngine for Client {
    async fn compose(&self, project: &Project, phase: Phase) -> Result<()> {
        let command = compose_command(&self.access, project, phase)?;
        let policy = ReadOnlyExecPolicy {
            overall_timeout: Some(OPERATION_TIMEOUT),
            timeout: COMPOSE_TIMEOUT,
            denied: COMPOSE_PERMISSION,
            ..ACCESS_POLICY
        };
        let (_, code) = tokio::time::timeout_at(
            self.deadline,
            read_only_exec(self.session, command, &policy, 16 * 1024),
        )
        .await
        .map_err(|_| anyhow!(COMPOSE_TIMEOUT))??;
        match code {
            0 => Ok(()),
            70 => Err(anyhow!("Docker 未运行")),
            77 => Err(anyhow!(COMPOSE_PERMISSION)),
            80 => Err(anyhow!("未安装 Docker Compose，请安装 Compose 插件后重试")),
            81 => Err(anyhow!(SOURCE)),
            82 => Err(anyhow!("编排配置校验失败，请检查原配置和环境文件")),
            83 => Err(anyhow!("原配置中缺少当前编排服务，重建已取消")),
            84 => Err(anyhow!(
                "编排已停止，镜像拉取失败，请检查仓库权限和网络后重新部署"
            )),
            85 => Err(anyhow!(
                "编排已停止，镜像构建失败，请检查构建文件后重新部署"
            )),
            86 => Err(anyhow!(
                "编排镜像已构建，但部分服务可能启动失败，请检查原配置并重新部署"
            )),
            87 => Err(anyhow!("无法启动编排，部分服务可能已启动，请刷新列表检查")),
            88 => Err(anyhow!("无法停止编排，部分服务可能已停止，请刷新列表检查")),
            89 => Err(anyhow!("无法移除编排，部分服务可能已移除，请刷新列表检查")),
            _ => Err(anyhow!("Docker 编排操作失败，请刷新列表检查")),
        }
    }
}

async fn operate<E: ComposeEngine>(
    engine: &E,
    project: &Project,
    action: DockerComposeAction,
) -> Result<Option<String>> {
    match action {
        DockerComposeAction::Start => engine.compose(project, Phase::Start).await?,
        DockerComposeAction::Stop => engine.compose(project, Phase::Stop).await?,
        DockerComposeAction::Delete => engine.compose(project, Phase::Down).await?,
        DockerComposeAction::Rebuild => {
            // Do not stop any service until the original configuration and service names are valid.
            engine.compose(project, Phase::Check).await?;
            engine.compose(project, Phase::Down).await?;
            let mut retained = false;
            for image in &project.images {
                match image_action(engine, DockerImageAction::Delete, Some(image)).await {
                    Ok(()) => {}
                    Err(error)
                        if matches!(
                            error.to_string().as_str(),
                            "镜像正在被容器使用，无法删除" | "镜像仍被容器或其他资源引用，无法删除"
                        ) =>
                    {
                        retained = true
                    }
                    Err(error) if matches!(error.to_string().as_str(), TIMEOUT | PERMISSION) => {
                        return Err(error)
                    }
                    Err(_) => {
                        return Err(anyhow!(
                            "编排已停止，但旧镜像移除失败，请检查镜像状态后重新部署"
                        ))
                    }
                }
            }
            engine.compose(project, Phase::Rebuild).await?;
            if retained {
                return Ok(Some("编排已重建，仍被其他资源引用的旧镜像已保留".into()));
            }
        }
    }
    Ok(None)
}

pub(crate) async fn run(
    session: u32,
    name: &str,
    action: DockerComposeAction,
) -> Result<Option<String>> {
    validate_docker_id(DockerResourceKind::Compose, name)?;
    let result = async {
        let client = Client {
            session,
            access: Access::prepare(session).await?,
            deadline: Instant::now() + OPERATION_TIMEOUT,
        };
        let filters =
            component(&json!({"label":[format!("com.docker.compose.project={name}")]}).to_string());
        let response = client
            .request(
                Method::GET,
                format!("/containers/json?all=true&filters={filters}"),
                None,
            )
            .await?;
        response.expect(&[200], "无法读取编排，请刷新后重试")?;
        let project = project_from_json(
            name,
            &response.json()?,
            matches!(action, DockerComposeAction::Rebuild),
        )?;
        // Reuse container locks so project actions cannot race a container upgrade in another tab.
        let _guards = project
            .containers
            .iter()
            .map(|id| OperationGuard::acquire(id))
            .collect::<Result<Vec<_>>>()?;
        operate(&client, &project, action).await
    }
    .await;
    result.map_err(|error| match error.to_string().as_str() {
        PERMISSION => anyhow!(COMPOSE_PERMISSION),
        TIMEOUT => anyhow!(COMPOSE_TIMEOUT),
        _ => error,
    })
}

#[cfg(test)]
#[path = "docker_compose_tests.rs"]
mod tests;
