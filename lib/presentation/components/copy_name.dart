/// 为同级副本选择可直接保存的名称，仍允许用户在新增表单里修改。
String copyName(String source, {required bool Function(String) isTaken}) {
  var suffix = 2;
  var name = '$source ($suffix)';
  while (isTaken(name)) {
    name = '$source (${++suffix})';
  }
  return name;
}
