use anyhow::{anyhow, Result};
use std::time::Duration;

use super::ssh::{
    defer_sudo_probe, read_only_exec, server_status_command, should_probe_sudo, ReadOnlyExecPolicy,
    SudoProbe,
};

const POLICY: ReadOnlyExecPolicy = ReadOnlyExecPolicy {
    overall_timeout: Some(Duration::from_secs(8)),
    closed: "网络端口连接已关闭",
    timeout: "网络端口查询超时，请重试",
    connection: "无法查询网络端口，请检查连接",
    denied: "此连接不允许查询网络端口",
    too_large: "网络端口数据过大，无法读取",
    incomplete: "网络端口查询未完成，请重试",
};

/// 固定只读命令，独立 exec 通道，无 PTY，不读取进程命令行参数。
pub async fn ssh_read_network_ports(session_id: u32) -> Result<String> {
    let probe = should_probe_sudo(session_id, SudoProbe::Ports);
    let mut command = server_status_command(include_str!("network_ports.sh"));
    if !probe {
        command.push_str(" paga-ports skip");
    }
    let (output, code) = read_only_exec(session_id, command, &POLICY, 2 * 1024 * 1024).await?;
    match code {
        0 => {
            let output = String::from_utf8_lossy(&output).into_owned();
            if probe && output.lines().nth(1) == Some("ACCESS LIMITED") {
                defer_sudo_probe(session_id, SudoProbe::Ports);
            }
            Ok(output)
        }
        64 => Err(anyhow!("网络端口仅支持 Linux 和 macOS")),
        69 => Err(anyhow!("未找到端口采集工具，请安装 ss 或 lsof")),
        77 => Err(anyhow!("没有权限读取网络端口")),
        _ => Err(anyhow!("无法读取网络端口，请重试")),
    }
}

#[cfg(all(test, unix))]
#[path = "network_ports_tests.rs"]
mod tests;
