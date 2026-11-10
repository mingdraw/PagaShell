import 'package:get/get.dart';

import '../../domain/ssh/docker_manager.dart';
import '../components/app_icon.dart';

extension DockerResourceLabels on DockerResourceKind {
  String get label => switch (this) {
    DockerResourceKind.compose => '编排'.tr,
    DockerResourceKind.container => '容器'.tr,
    DockerResourceKind.image => '镜像'.tr,
    DockerResourceKind.network => '网络'.tr,
    DockerResourceKind.volume => '存储卷'.tr,
  };

  AppIcons get icon => switch (this) {
    DockerResourceKind.compose => AppIcons.compose,
    DockerResourceKind.container => AppIcons.container,
    DockerResourceKind.image => AppIcons.layers,
    DockerResourceKind.network => AppIcons.network,
    DockerResourceKind.volume => AppIcons.database,
  };

  String get detailsTitle => switch (this) {
    DockerResourceKind.compose => '编排详情'.tr,
    DockerResourceKind.container => '容器详情'.tr,
    DockerResourceKind.image => '镜像详情'.tr,
    DockerResourceKind.network => '网络详情'.tr,
    DockerResourceKind.volume => '存储卷详情'.tr,
  };
}

extension DockerFieldLabels on DockerField {
  String get label => switch (this) {
    DockerField.image => '镜像'.tr,
    DockerField.state => '状态'.tr,
    DockerField.status => '运行状态'.tr,
    DockerField.ports => '端口映射'.tr,
    DockerField.networks => '网络'.tr,
    DockerField.createdAt => '创建时间'.tr,
    DockerField.size => '大小'.tr,
    DockerField.tags => '镜像标签'.tr,
    DockerField.digests => '镜像摘要'.tr,
    DockerField.driver => '驱动'.tr,
    DockerField.scope => '作用域'.tr,
    DockerField.health => '健康状态'.tr,
    DockerField.startedAt => '启动时间'.tr,
    DockerField.finishedAt => '停止时间'.tr,
    DockerField.exitCode => '退出码'.tr,
    DockerField.restartCount => '重启次数'.tr,
    DockerField.mounts => '挂载'.tr,
    DockerField.platform => '系统平台'.tr,
    DockerField.architecture => '架构'.tr,
    DockerField.internal => '内部网络'.tr,
    DockerField.ipv6 => '启用 IPv6'.tr,
    DockerField.attachable => '允许手动连接'.tr,
    DockerField.ingress => 'Ingress 网络'.tr,
    DockerField.ipam => '子网 / 网关'.tr,
    DockerField.containers => '已连接容器'.tr,
    DockerField.mountpoint => '挂载路径'.tr,
    DockerField.usage => '使用状态'.tr,
    DockerField.services => '服务'.tr,
    DockerField.serviceCount => '服务数量'.tr,
    DockerField.containerCount => '容器数量'.tr,
    DockerField.workingDirectory => '工作目录'.tr,
    DockerField.configFiles => '配置文件'.tr,
    DockerField.composeVersion => 'Compose 版本'.tr,
  };

  String display(String value) {
    if (this == DockerField.usage) {
      return switch (value) {
        'used' => '使用中'.tr,
        'unused' => '未使用'.tr,
        _ => '使用状态未知'.tr,
      };
    }
    if (this == DockerField.tags && value.isEmpty) return '无标签'.tr;
    if (value.isEmpty) return '—';
    if (const {
      DockerField.internal,
      DockerField.ipv6,
      DockerField.attachable,
      DockerField.ingress,
    }.contains(this)) {
      return (value == 'true' ? '是' : '否').tr;
    }
    return value;
  }
}
