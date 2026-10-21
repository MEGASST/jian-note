# 简笺 JianNote

一个极简、离线、无需安装的 Windows 便签 / 笔记应用：双击就能写，关掉就保存，数据只留在本机。

![platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4)
![runtime](https://img.shields.io/badge/runtime-Windows%20PowerShell%205.1-5391FE)
![license](https://img.shields.io/badge/license-MIT-green)

收起一切干扰：左侧列出笔记，右侧直接写。没有账号、没有云同步、没有常驻后台，所有内容保存在
`%LOCALAPPDATA%\JianNote\notes.json`。

## 快速开始

1. 下载并解压发布包（Releases 中的 `jian-note-v0.1.0.zip`）。
2. 保持 `简笺.exe`、`JianNote.ps1`、`启动简笺.bat` 三个文件在**同一个文件夹**里。
3. 双击 `简笺.exe` 即可启动；首次启动会生成一条欢迎笔记。

> `简笺.exe` 只是启动器，它会到同目录寻找 `JianNote.ps1` 并交给系统自带的 PowerShell 运行，
> 所以不要只把 exe 单独复制出去。

## 功能

- 新建、编辑、自动保存（切换笔记或关闭窗口时也会保存）
- 标题、正文、标签全文搜索
- 笔记置顶
- “全部笔记”支持多选、批量导出、批量移入回收站
- 回收站、单条永久删除、一键清空
- 深色 / 浅色主题
- 导入 `.txt`、`.md` 与简笺 `.json` 备份
- 单篇导出 Markdown、全部导出 JSON 备份
- 快捷键：`Ctrl+N` 新建、`Ctrl+F` 搜索、`Ctrl+S` 保存、`Ctrl+E` 导出当前笔记、`Ctrl+Shift+E` 备份全部

## 数据与日志

| 内容 | 位置 |
| --- | --- |
| 笔记数据 | `%LOCALAPPDATA%\JianNote\notes.json` |
| 上一版备份 | `%LOCALAPPDATA%\JianNote\notes.backup.json` |
| 界面设置 | `%LOCALAPPDATA%\JianNote\settings.json` |
| 启动日志 | `%LOCALAPPDATA%\JianNote\startup.log` |

卸载方式：删除程序文件夹，再删除上面这个数据目录即可，不写注册表、不留后台服务。

## 项目结构

```text
.
├─ 简笺.exe                启动器（由 launcher/*.cs 编译而来）
├─ JianNote.ps1            主程序：界面与全部逻辑（PowerShell + WPF）
├─ 启动简笺.bat            备用启动入口
├─ launcher/
│  └─ JianNoteLauncher.cs  启动器源码：定位 PowerShell、写日志、异常弹窗
├─ build.ps1               重新编译启动器，可选打包 zip
├─ LICENSE                 MIT
└─ README.md
```

## 从源码构建

不需要安装 .NET SDK，用 Windows 自带的 .NET Framework 4 编译器即可：

```powershell
pwsh -File .\build.ps1          # 只生成 简笺.exe
pwsh -File .\build.ps1 -Zip     # 顺便打包 dist\jian-note-v0.1.0.zip
```

`JianNote.ps1` 无需编译，改完直接运行。

## 自测

```powershell
.\简笺.exe --self-test
```

该流程会走一遍“加载笔记 → 多选 → 批量移入回收站 → 清空回收站”，通过时退出码为 0，
输出 `Self-test passed.`。

## 兼容性

- Windows 10 / 11（自带 Windows PowerShell 5.1 与 .NET Framework 4.x）
- 无需管理员权限，不联网
- 首次运行可能提示“Windows 已保护你的电脑”（exe 未做代码签名）：
  点击“更多信息 → 仍要运行”即可

## 已知限制

- 当前是 0.1.0 原型版本
- 暂无 Markdown 预览、附件、清单、云同步
- 暂未提供安装包，绿色解压即用

## 许可证

[MIT](LICENSE)
