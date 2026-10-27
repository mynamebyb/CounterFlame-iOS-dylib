# CounterFlame 内部测试工具

CounterFlame（Unity IL2CPP）注入 dylib，standalone 形态，无 CydiaSubstrate 依赖，
arm64 + arm64e fat 二进制，可在 LiveContainer / 重签名环境注入。

## 功能

- 悬浮按钮「CF」：可全局拖动，点击打开菜单。
- 仅保留「获取摄像机」（无摄像机选择列表）。
- 固定类名列表（点击即获取类与对象并重新获取摄像机）：
  - `ScarletWork.Game.Audio.PlayerAudio`（真人玩家）
  - `ScarletWork.Training.ArenaBot`（人机）
  - `UnityEngine.BoxCollider`（物品 1）
  - `UnityEngine.Rigidbody`（物品 2）
- ESP：在对象名字上方绘制方框，并显示距离（m）；可独立开关方框/名字/距离/射线。
- 暗色 + 橙色主题；进游戏不自动弹窗。
- 日志：App 沙盒 Documents 下 `counterflame_tool.log`。

## 构建

GitHub Actions 自动编译，成品在 Actions 运行页 Artifacts 下载 `CounterFlameTool.dylib`。
本地：`make`（需 Theos）。
