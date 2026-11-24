# @ohos-rs/ability-plugin-clipboard

这是 `openharmony-ability-plugin-clipboard` 的 ArkTS HAR。插件经 `@ohos.pasteboard`
读写系统剪贴板(纯文本 / HTML / 图片),图片按 base64 PNG 契约桥接;读取类 action
在 ArkTS 侧先申请 `ohos.permission.READ_PASTEBOARD` 再调用 `getData()`。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-clipboard
```

## 装配

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-clipboard": "1.0.0-beta.0"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ClipboardPlugin())];
}
```

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.clipboard` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| action | `read-text`、`write-text`、`read-image`、`write-image`、`write-html`、`clear` |

写入类 action(`write-text`/`write-image`/`write-html`)与 `clear` 不需要任何权限。

## 权限:ohos.permission.READ_PASTEBOARD

读取类 action(`read-text`/`read-image`)受该权限管控(API 12 起剪贴板读取接口增加
权限管控)。该权限为**受限权限**:级别 `system_basic`、授权方式用户授权
(`user_grant`)、起始版本 11。

申请链共四步(官方 get-pastedata-permission-guidelines):

1. **场景审视**:受限权限仅特定场景可通过审核 —— PC/2in1 设备上的应用均可申请;
   其他设备仅白名单场景(银行卡号、口令、文档编辑、系统级输入法、开源框架)可申请。
2. **AGC 侧申请签名 Profile**:权限须包含在 profile 的 ACL 中,AGC 审核预计 3 个
   工作日反馈。缺失 ACL 条目时应用无法完成签名/安装 —— 这是 install 阶段的硬失败,
   与下文的运行时降级是两种不同性质的失败。
3. **应用 entry `module.json5` 声明**(须含 reason/usedScene):

   ```json5
   {
     "name": "ohos.permission.READ_PASTEBOARD",
     "reason": "$string:reason_read_pasteboard",
     "usedScene": {
       "abilities": ["EntryAbility"],
       "when": "inuse"
     }
   }
   ```

4. **运行时向用户申请**:由插件的 `ensureReadPermission` 调
   `requestPermissionsFromUser` 弹窗完成(PC/2in1 首次申请默认授予、不弹窗,用户仅能
   在设置中切换允许/禁止)。

本 HAR 自身的 module.json5 不声明该权限 —— 声明由应用侧 entry module.json5 负责:
tauri-cli 的 open-harmony 模板已内置该声明与 `reason_read_pasteboard` 字符串资源,
旧项目或自定义 module.json5 需自行核对补齐。

### 未声明 / 被拒绝时的降级表现

`ensureReadPermission` 请求失败(未声明、缺 ACL)或被用户拒绝时,插件只记录
console.warn,不向调用方抛权限错误,读取按"空剪贴板"降级:

- `read-text`:`getData()` 返回空板 → 桥接返回空文本 → Rust 侧 `read_text` 解析为
  空字符串 `""`;
- `read-image`:空板 → `getPrimaryPixelMap()` 为 null → 抛
  `clipboard does not contain an image`。

两者与真空剪贴板不可区分 —— 这是有意设计的降级契约,保证缺权限不把可用的读取
变成硬失败(见 `ClipboardPlugin.ets` 中 `ensureReadPermission` 的注释)。

### 读取的桥接超时档(60s)

读取类 action(`read-text`/`read-image`)的 Rust 桥接调用使用 **60s** 超时,而
非桥接默认的 15s(`plugin-webview` 快照族 / `plugin-files` / `plugin-permission`
同款 60s 重动作先例):`READ_PASTEBOARD` 为 `user_grant`,手机端首次读取会在桥接
窗口内弹系统权限对话框,用户作答可能超过 15s。用户在 60s 内作答则读取正常完成;
超时未作答时 Rust 侧收到 timeout 错误(与「未声明/被拒」的空板降级不同,这是
显式失败),而 ArkTS 侧读取随后仍会完成、结果被丢弃。写入类与 `clear` 不走权限
弹窗,保持 15s 默认预算。

Rust 侧 facade 见 [crates/plugin-clipboard](../../crates/plugin-clipboard),
完整插件规则见[插件开发规范](../../docs/plugin-development-standard.md)。
