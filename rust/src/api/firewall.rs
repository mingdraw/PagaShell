use std::net::IpAddr;
use std::time::Duration;

use anyhow::{anyhow, ensure, Result};

use super::docker::shell_argument;
use super::ssh::{read_only_exec, server_status_command, ReadOnlyExecPolicy};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FirewallBackendKind {
    Firewalld,
    Ufw,
    Nftables,
    Iptables,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FirewallActionKind {
    Allow,
    Deny,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FirewallProtocolKind {
    Tcp,
    Udp,
    TcpUdp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FirewallServiceActionKind {
    Enable,
    Disable,
    Reload,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FirewallRuleSpec {
    pub action: FirewallActionKind,
    pub protocol: FirewallProtocolKind,
    pub port: String,
    pub source: String,
    pub priority: Option<i16>,
    pub comment: String,
}

const FIREWALL_READ_POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(12)),
    closed: "防火墙管理连接已关闭",
    timeout: "防火墙查询超时，请重试",
    connection: "无法查询防火墙，请检查连接",
    denied: "此连接不允许查询防火墙",
    too_large: "防火墙规则数据过大，无法读取",
    incomplete: "防火墙查询未完成，请重试",
};

const FIREWALL_MUTATE_POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(25)),
    closed: "防火墙管理连接已关闭",
    timeout: "防火墙操作超时，请刷新规则列表确认状态",
    connection: "无法执行防火墙操作，请检查连接",
    denied: "此连接不允许管理防火墙",
    too_large: "防火墙操作响应过大",
    incomplete: "防火墙操作未完成，请刷新规则列表确认状态",
};

/// 读取当前 Linux 主机防火墙状态、端口规则及监听端口关联进程。
pub async fn ssh_read_firewall(session_id: u32) -> Result<String> {
    let command = firewall_read_command();
    let (output, code) =
        read_only_exec(session_id, command, &FIREWALL_READ_POLICY, 4 * 1024 * 1024).await?;
    match code {
        0 => Ok(String::from_utf8_lossy(&output).into_owned()),
        64 => Err(anyhow!("不支持当前系统的防火墙，仅支持 Linux")),
        69 => Err(anyhow!(
            "未检测到支持的防火墙（firewalld、ufw、nftables 或 iptables）"
        )),
        77 => Err(anyhow!(
            "没有权限读取防火墙配置，请使用 root 或配置免密 sudo"
        )),
        _ => Err(anyhow!("无法读取防火墙配置，请重试")),
    }
}

/// 批量新增 TCP/UDP 端口规则；所有参数在 Rust 侧严格校验后再执行远端命令。
pub async fn ssh_add_firewall_rules(
    session_id: u32,
    backend: FirewallBackendKind,
    rules: Vec<FirewallRuleSpec>,
) -> Result<()> {
    let command = firewall_add_command(backend, &rules)?;
    let (_, code) = read_only_exec(session_id, command, &FIREWALL_MUTATE_POLICY, 64 * 1024).await?;
    map_mutate_exit(code)
}

/// 删除单条防火墙规则；执行前再次核对规则标识，防止并发修改导致误删。
pub async fn ssh_delete_firewall_rule(
    session_id: u32,
    backend: FirewallBackendKind,
    existing_raw: String,
) -> Result<()> {
    let command = firewall_delete_command(backend, &existing_raw)?;
    let (_, code) = read_only_exec(session_id, command, &FIREWALL_MUTATE_POLICY, 64 * 1024).await?;
    map_mutate_exit(code)
}

/// 开启、关闭或重载受支持的防火墙服务（firewalld / ufw / nftables）。
pub async fn ssh_run_firewall_service_action(
    session_id: u32,
    backend: FirewallBackendKind,
    action: FirewallServiceActionKind,
) -> Result<()> {
    let command = firewall_service_command(backend, action)?;
    let (_, code) = read_only_exec(session_id, command, &FIREWALL_MUTATE_POLICY, 64 * 1024).await?;
    match code {
        0 => Ok(()),
        64 => Err(anyhow!("不支持当前系统的防火墙，仅支持 Linux")),
        69 => Err(anyhow!("当前系统不支持此防火墙服务操作")),
        72 => Err(anyhow!("防火墙服务操作参数无效")),
        77 => Err(anyhow!(
            "没有权限管理防火墙服务，请使用 root 或配置免密 sudo"
        )),
        _ => Err(anyhow!("防火墙服务操作失败，请刷新状态后检查")),
    }
}

fn map_mutate_exit(code: u32) -> Result<()> {
    match code {
        0 => Ok(()),
        64 => Err(anyhow!("不支持当前系统的防火墙，仅支持 Linux")),
        69 => Err(anyhow!("未找到目标防火墙工具，请刷新后重试")),
        70 => Err(anyhow!("防火墙未启用，请先开启防火墙")),
        72 => Err(anyhow!("规则参数无效，请检查端口与 IP 格式")),
        73 => Err(anyhow!(
            "当前系统不支持 IPv6 防火墙规则（未找到 ip6tables）"
        )),
        77 => Err(anyhow!(
            "没有权限修改防火墙规则，请使用 root 或配置免密 sudo"
        )),
        78 => Err(anyhow!("防火墙规则已变化，请刷新后重试")),
        _ => Err(anyhow!("防火墙规则操作失败，请刷新列表检查")),
    }
}

fn backend_name(backend: FirewallBackendKind) -> &'static str {
    match backend {
        FirewallBackendKind::Firewalld => "firewalld",
        FirewallBackendKind::Ufw => "ufw",
        FirewallBackendKind::Nftables => "nftables",
        FirewallBackendKind::Iptables => "iptables",
    }
}

fn action_name(action: FirewallActionKind) -> &'static str {
    match action {
        FirewallActionKind::Allow => "allow",
        FirewallActionKind::Deny => "deny",
    }
}

fn protocol_name(protocol: FirewallProtocolKind) -> &'static str {
    match protocol {
        FirewallProtocolKind::Tcp => "tcp",
        FirewallProtocolKind::Udp => "udp",
        FirewallProtocolKind::TcpUdp => "tcpudp",
    }
}

fn service_action_name(action: FirewallServiceActionKind) -> &'static str {
    match action {
        FirewallServiceActionKind::Enable => "enable",
        FirewallServiceActionKind::Disable => "disable",
        FirewallServiceActionKind::Reload => "reload",
    }
}

pub(super) fn firewall_read_command() -> String {
    server_status_command(include_str!("firewall_read.sh"))
}

pub(super) fn firewall_service_command(
    backend: FirewallBackendKind,
    action: FirewallServiceActionKind,
) -> Result<String> {
    ensure!(
        backend != FirewallBackendKind::Iptables,
        "iptables 不支持直接启停服务，请通过规则进行维护"
    );
    Ok(format!(
        "{} paga-firewall-svc {} {}",
        server_status_command(include_str!("firewall_service.sh")),
        shell_argument(backend_name(backend)),
        shell_argument(service_action_name(action)),
    ))
}

struct ValidatedRule {
    action: &'static str,
    protocol: &'static str,
    port: String,
    source: String,
    family: &'static str,
    priority: String,
    comment: String,
}

fn validate_rule_spec(
    backend: FirewallBackendKind,
    spec: &FirewallRuleSpec,
) -> Result<ValidatedRule> {
    let port = validate_port(&spec.port)?;
    let (source, family) = validate_source(&spec.source)?;
    let comment = if backend == FirewallBackendKind::Firewalld {
        String::new()
    } else {
        validate_comment(&spec.comment)?
    };
    let priority = if backend == FirewallBackendKind::Firewalld {
        spec.priority.map(|p| p.to_string()).unwrap_or_default()
    } else {
        String::new()
    };
    Ok(ValidatedRule {
        action: action_name(spec.action),
        protocol: protocol_name(spec.protocol),
        port,
        source,
        family,
        priority,
        comment,
    })
}

fn append_validated_rule(args: &mut Vec<String>, rule: &ValidatedRule) {
    args.push(shell_argument(rule.action));
    args.push(shell_argument(rule.protocol));
    args.push(shell_argument(&rule.port));
    args.push(shell_argument(&rule.source));
    args.push(shell_argument(rule.family));
    args.push(shell_argument(&rule.priority));
    args.push(shell_argument(&rule.comment));
}

pub(super) fn firewall_add_command(
    backend: FirewallBackendKind,
    rules: &[FirewallRuleSpec],
) -> Result<String> {
    ensure!(!rules.is_empty(), "请至少配置一条防火墙规则");
    ensure!(rules.len() <= 64, "单次最多创建 64 条防火墙规则");
    let mut args = vec![
        shell_argument("add"),
        shell_argument(backend_name(backend)),
        shell_argument(&rules.len().to_string()),
    ];
    for spec in rules {
        let validated = validate_rule_spec(backend, spec)?;
        append_validated_rule(&mut args, &validated);
    }
    Ok(format!(
        "{} paga-firewall-mut {}",
        server_status_command(include_str!("firewall_mutate.sh")),
        args.join(" ")
    ))
}

pub(super) fn firewall_delete_command(
    backend: FirewallBackendKind,
    existing_raw: &str,
) -> Result<String> {
    validate_existing_raw(backend, existing_raw)?;
    Ok(format!(
        "{} paga-firewall-mut {} {} {}",
        server_status_command(include_str!("firewall_mutate.sh")),
        shell_argument("delete"),
        shell_argument(backend_name(backend)),
        shell_argument(existing_raw)
    ))
}

pub(super) fn validate_port(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    ensure!(
        !trimmed.is_empty() && trimmed.len() <= 11,
        "端口格式无效，请输入 1-65535 的端口或端口段"
    );
    if let Some((start_str, end_str)) = trimmed.split_once('-') {
        ensure!(
            !start_str.is_empty()
                && !end_str.is_empty()
                && start_str.bytes().all(|b| b.is_ascii_digit())
                && end_str.bytes().all(|b| b.is_ascii_digit()),
            "端口格式无效，请输入 1-65535 的端口或端口段"
        );
        let start = start_str
            .parse::<u16>()
            .map_err(|_| anyhow!("端口格式无效，请输入 1-65535 的端口或端口段"))?;
        let end = end_str
            .parse::<u16>()
            .map_err(|_| anyhow!("端口格式无效，请输入 1-65535 的端口或端口段"))?;
        ensure!(
            start >= 1 && start < end,
            "端口段无效，起始端口必须小于结束端口（1-65535）"
        );
        return Ok(format!("{start}-{end}"));
    }
    ensure!(
        trimmed.bytes().all(|b| b.is_ascii_digit()),
        "端口格式无效，请输入 1-65535 的端口或端口段"
    );
    let port = trimmed
        .parse::<u16>()
        .map_err(|_| anyhow!("端口格式无效，请输入 1-65535 的端口或端口段"))?;
    ensure!(port >= 1, "端口格式无效，请输入 1-65535 的端口或端口段");
    Ok(port.to_string())
}

pub(super) fn validate_source(raw: &str) -> Result<(String, &'static str)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok((String::new(), "any"));
    }
    if let Some((ip_str, prefix_str)) = trimmed.split_once('/') {
        ensure!(
            !prefix_str.is_empty() && prefix_str.bytes().all(|b| b.is_ascii_digit()),
            "IP 或网段格式无效，请检查后重试"
        );
        let prefix = prefix_str
            .parse::<u8>()
            .map_err(|_| anyhow!("IP 或网段格式无效，请检查后重试"))?;
        let ip = ip_str
            .parse::<IpAddr>()
            .map_err(|_| anyhow!("IP 或网段格式无效，请检查后重试"))?;
        return match ip {
            IpAddr::V4(v4) if prefix <= 32 => Ok((format!("{v4}/{prefix}"), "ipv4")),
            IpAddr::V6(v6) if prefix <= 128 => Ok((format!("{v6}/{prefix}"), "ipv6")),
            _ => Err(anyhow!("IP 或网段格式无效，请检查后重试")),
        };
    }
    let ip = trimmed
        .parse::<IpAddr>()
        .map_err(|_| anyhow!("IP 或网段格式无效，请检查后重试"))?;
    match ip {
        IpAddr::V4(v4) => Ok((v4.to_string(), "ipv4")),
        IpAddr::V6(v6) => Ok((v6.to_string(), "ipv6")),
    }
}

pub(super) fn validate_comment(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    ensure!(
        trimmed.chars().count() <= 128 && trimmed.len() <= 256,
        "描述不能超过 128 个字符"
    );
    ensure!(
        !trimmed.chars().any(|ch| ch.is_control()
            || matches!(
                ch,
                '\'' | '"' | '\\' | '`' | '$' | ';' | '|' | '&' | '<' | '>'
            )),
        "描述包含不支持的特殊字符"
    );
    Ok(trimmed.to_owned())
}

pub(super) fn validate_existing_raw(backend: FirewallBackendKind, raw: &str) -> Result<()> {
    ensure!(
        !raw.is_empty() && raw.len() <= 1024 && !raw.chars().any(char::is_control),
        "防火墙规则标识无效，请刷新列表"
    );
    match backend {
        FirewallBackendKind::Firewalld => {
            if let Some(spec) = raw.strip_prefix("port:") {
                let (port, proto) = spec
                    .split_once('/')
                    .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
                ensure!(
                    matches!(proto, "tcp" | "udp"),
                    "防火墙规则标识无效，请刷新列表"
                );
                validate_port(port)?;
                Ok(())
            } else if let Some(rule) = raw.strip_prefix("rich:") {
                ensure!(rule.starts_with("rule "), "防火墙规则标识无效，请刷新列表");
                Ok(())
            } else {
                Err(anyhow!("防火墙规则标识无效，请刷新列表"))
            }
        }
        FirewallBackendKind::Ufw => {
            let rest = raw
                .strip_prefix("ufw:")
                .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
            let (num, body) = rest
                .split_once(':')
                .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
            ensure!(
                !num.is_empty()
                    && num.bytes().all(|b| b.is_ascii_digit())
                    && num.parse::<u32>().is_ok_and(|n| n >= 1)
                    && !body.trim().is_empty(),
                "防火墙规则标识无效，请刷新列表"
            );
            Ok(())
        }
        FirewallBackendKind::Nftables => {
            let rest = raw
                .strip_prefix("nft:")
                .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
            let parts: Vec<_> = rest.split('|').collect();
            ensure!(parts.len() == 4, "防火墙规则标识无效，请刷新列表");
            ensure!(
                matches!(parts[0], "inet" | "ip" | "ip6")
                    && is_nft_ident(parts[1])
                    && is_nft_ident(parts[2])
                    && !parts[3].is_empty()
                    && parts[3].bytes().all(|b| b.is_ascii_digit())
                    && parts[3].parse::<u64>().is_ok_and(|n| n >= 1),
                "防火墙规则标识无效，请刷新列表"
            );
            Ok(())
        }
        FirewallBackendKind::Iptables => {
            let rest = raw
                .strip_prefix("iptables:")
                .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
            let (ver, rest2) = rest
                .split_once(':')
                .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
            let (num, line) = rest2
                .split_once(':')
                .ok_or_else(|| anyhow!("防火墙规则标识无效，请刷新列表"))?;
            ensure!(
                matches!(ver, "v4" | "v6")
                    && !num.is_empty()
                    && num.bytes().all(|b| b.is_ascii_digit())
                    && num.parse::<u32>().is_ok_and(|n| n >= 1)
                    && line.starts_with("-A INPUT "),
                "防火墙规则标识无效，请刷新列表"
            );
            Ok(())
        }
    }
}

fn is_nft_ident(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
}

#[cfg(all(test, unix))]
#[path = "firewall_tests.rs"]
mod tests;
