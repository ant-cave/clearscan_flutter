# 项目约定

## 构建

- 构建 APK 时只产出 armv8 (arm64-v8a) 架构，其余架构（armeabi-v7a、x86_64 等）不需要。
- 命令示例：`flutter build apk --target-platform android-arm64`
