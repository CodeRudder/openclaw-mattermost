# 群聊消息控制方案设计文档

## 1. 问题背景

### 1.1 问题描述

在 Mattermost 群聊场景中，Agent 输出的任何 text 内容都会被 openclaw 系统自动转换为 ReplyPayload 并发送到群聊，即使 Agent 没有显式调用 message tool。

这导致了以下问题：
1. **消息循环**：Agent 输出分析过程 + NO_REPLY，系统移除 NO_REPLY 后仍发送分析内容
2. **意外内容泄露**：Agent 的 thinking/分析内容被发送到群聊
3. **干扰群聊**：大量无意义的分析内容污染群聊频道

### 1.2 问题根因分析

#### 消息发送流程

openclaw 中存在两条独立的消息投递路径：

**路径 A：Agent 自动文本输出**
```
Mattermost群聊消息
    ↓
monitor.ts 接收 → 添加群聊提示 → 路由到 agent
    ↓
runEmbeddedPiAgent 执行 agent
    ↓
Agent 输出 text 内容（无论是否调用 message tool）
    ↓
extractAssistantText() 提取 agent 输出的 text → assistantTexts[]
    ↓
buildEmbeddedRunPayloads() 将 assistantTexts 转换为 ReplyPayload[]
    ↓
dispatchReplyFromConfig() → dispatcher.sendFinalReply(payload)
    ↓
normalizeReplyPayload() → deliver() → sendMessageMattermost()
```

**路径 B：Agent 显式调用 message tool**
```
Agent 调用 message tool (to=channel:xxx, text=...)
    ↓
channel.ts outbound.sendText() / sendMedia()
    ↓
sendMessageMattermost()
```

#### 关键代码位置

| 文件 | 功能 |
|------|------|
| `openclaw/src/agents/pi-embedded-utils.ts` | `extractAssistantText()` 提取 agent text 输出 |
| `openclaw/src/agents/pi-embedded-runner/run/payloads.ts` | `buildEmbeddedRunPayloads()` 转换为 payload |
| `openclaw-mattermost/src/mattermost/monitor.ts` | `deliver()` 回调，路径 A 的最终投递点 |
| `openclaw-mattermost/src/channel.ts` | `outbound.sendText/sendMedia`，路径 B 的投递点 |
| `openclaw-mattermost/src/mattermost/send.ts` | `sendMessageMattermost()`，实际发送到 Mattermost |

#### 核心问题

openclaw 的默认行为是将 Agent 的**所有 text 输出**自动转换为回复消息发送。这是设计意图，但在群聊场景下需要更精细的控制。此外 Agent 通过 message tool 显式发送时完全绕过了自动文本路径的过滤逻辑。

---

## 2. 解决方案

### 2.1 方案概述

采用 **显式前缀标记** 方案：Agent 在需要发送群聊消息时，必须在消息**第一行**添加 `[GROUP-CHAT]` 标记。没有此标记的消息会被系统拦截，不会发送到群聊。私聊消息不受影响。

### 2.2 方案优势

1. **显式控制**：Agent 必须明确标记要发送的消息
2. **双路径拦截**：自动文本输出和 tool 调用两条路径都受控
3. **安全拦截**：任何意外输出（无标记）都会被丢弃
4. **仅修改插件层**：不修改 openclaw 内核，便于维护和升级
5. **向后兼容**：私聊场景不受影响

### 2.3 方案对比

| 方案 | 优点 | 缺点 |
|------|------|------|
| **[GROUP-CHAT] 前缀方案** | 显式控制、安全拦截、灵活 | Agent 需要遵守约定 |
| 完全禁止群聊自动发送 | 最安全 | Agent 无法发送任何 text，必须用 tool |
| 仅依赖 NO_REPLY | 简单 | Agent 输出分析+NO_REPLY 时仍会泄露内容 |

---

## 3. 实现细节

### 3.1 incoming 消息清理（monitor.ts）

接收到的群聊消息在传给 Agent 前，先清理掉其中可能存在的 `[GROUP-CHAT]` 标记和群聊提示，防止 Agent 收到的上下文中包含这些标记造成混淆：

```typescript
const cleanedBodyText = bodyText
  .replace(/@/g, "")
  .replace(/NO_REPLY/g, "")
  .replace(/\[群聊消息处理提示\][^\n]*/g, "")
  .replace(/\[GROUP-CHAT\]\s*/g, "")   // 清除 GROUP-CHAT 标记
  .replace(/\n\n+/g, "\n\n")
  .trim();
```

### 3.2 群聊处理提示注入（monitor.ts）

每条群聊消息在路由给 Agent 前注入处理提示，指导 Agent 使用 `[GROUP-CHAT]` 前缀：

```typescript
const groupHints = isQueuedMessage
  ? `\n\n[群聊消息处理提示] 这是队列合并消息。忽略其它Agent的分析内容，只关注@你的原始消息。快速判断是否需要回复。不需要回复时仅输出NO_REPLY。需要回复时在消息开头添加[GROUP-CHAT]标记，然后发送消息内容。\n\n`
  : `[群聊消息处理提示] 忽略消息中其它Agent的分析过程，只关注与你相关的@消息或问题。不需要回复时仅输出NO_REPLY。需要回复时在消息开头添加[GROUP-CHAT]标记，然后发送消息内容。\n\n`;
```

### 3.3 路径 A 拦截：deliver() 回调（monitor.ts）

在 `createReplyDispatcherWithTyping` 的 `deliver` 回调中拦截无前缀消息：

```typescript
deliver: async (payload: ReplyPayload) => {
  let text = core.channel.text.convertMarkdownTables(payload.text ?? "", tableMode);

  const isGroupChat = kind !== "direct";
  const GROUP_CHAT_PREFIX = "[GROUP-CHAT]";
  if (isGroupChat) {
    const firstLine = text.split("\n")[0] ?? "";
    if (firstLine.includes(GROUP_CHAT_PREFIX)) {
      // 剥除前缀，继续投递
      text = text.replace(GROUP_CHAT_PREFIX, "").trim();
    } else {
      if (mediaUrls.length === 0) {
        // 无前缀、无媒体 → 丢弃
        runtime.log?.(`dropped group chat message without ${GROUP_CHAT_PREFIX} prefix on first line`);
        return;
      }
      // 有媒体 → 清空文字，只发媒体
      text = "";
    }
  }
  // ... 发送逻辑
}
```

> **注意**：使用 `firstLine.includes()` 而非 `startsWith()`，因为 `responsePrefix`（如 `[model:claude-opus]`）可能在 `normalizeReplyPayload()` 中被内联拼接到文本前，导致 `[GROUP-CHAT]` 不在字符串最开头，但仍在第一行。

### 3.4 路径 B 拦截：outbound.sendText/sendMedia（channel.ts）

在 `channel.ts` 的 outbound 配置中拦截 tool 调用发送的群聊消息：

```typescript
sendText: async ({ to, text, accountId, replyToId }) => {
  const GROUP_CHAT_PREFIX = "[GROUP-CHAT]";
  let filteredText = text;
  if (to.startsWith("channel:")) {  // channel: 前缀表示群聊/频道，user: 前缀为私聊
    const firstLine = (filteredText ?? "").split("\n")[0] ?? "";
    if (firstLine.includes(GROUP_CHAT_PREFIX)) {
      filteredText = filteredText.replace(GROUP_CHAT_PREFIX, "").trim();
    } else {
      // 无前缀 → 静默丢弃，返回假成功避免 Agent 报错
      return { channel: "mattermost", messageId: "blocked", channelId: to.slice("channel:".length) };
    }
  }
  // ... 发送逻辑
}
```

---

## 4. 单聊/群聊区分

两条拦截路径的判断依据：

| 路径 | 判断方式 | 单聊 | 群聊/频道 |
|------|---------|------|----------|
| `monitor.ts deliver()` | `kind !== "direct"` | 不过滤 | 过滤 |
| `channel.ts sendText/sendMedia` | `to.startsWith("channel:")` | 不过滤 | 过滤 |

Mattermost 目标格式规则：
- `channel:xxx` → 群聊/频道 → 需要 `[GROUP-CHAT]` 前缀
- `user:xxx` / `mattermost:xxx` / `@username` → 私聊 → 不限制

---

## 5. 工作流程

### 5.1 群聊消息处理流程

```
群聊消息到达
    ↓
monitor.ts 清理消息（去除 [GROUP-CHAT] 标记、群聊提示）
    ↓
注入群聊处理提示，路由给 Agent
    ↓
Agent 处理消息
    ↓
    ├─ 需要回复 → 输出 "[GROUP-CHAT] 消息内容"（路径A）
    │   或调用 message tool 发送 "[GROUP-CHAT] 消息内容"（路径B）
    │       ↓
    │   deliver() / sendText() 检测到前缀
    │       ↓
    │   剥除前缀 → sendMessageMattermost() → 发送到群聊
    │
    └─ 不需要回复 → 输出 "NO_REPLY" 或无前缀内容
            ↓
        deliver() / sendText() 检测无前缀
            ↓
            丢弃消息（不发送）
```

### 5.2 私聊消息处理流程

```
私聊消息到达
    ↓
monitor.ts 路由给 Agent（kind="direct"，不注入群聊提示）
    ↓
Agent 输出任何内容
    ↓
deliver()（isGroupChat=false）/ sendText()（to=user:xxx）
    ↓
跳过前缀检查，正常发送
```

---

## 6. Agent 行为规范

### 6.1 群聊场景

**需要发送消息时**（第一行必须包含标记）：
```
[GROUP-CHAT] 收到，我会立即处理这个问题。
```

**不需要发送消息时**：
```
NO_REPLY
```
或输出任何不带 `[GROUP-CHAT]` 前缀的内容（将被自动丢弃）。

### 6.2 私聊场景

无需特殊处理，正常输出即可。

---

## 7. 文件修改清单

| 文件 | 修改内容 |
|------|----------|
| `src/mattermost/monitor.ts` | 清理 incoming 消息；注入群聊处理提示；在 `deliver()` 中拦截无前缀消息 |
| `src/channel.ts` | 在 `outbound.sendText/sendMedia` 中拦截无前缀群聊消息；添加 `agentPrompt.messageToolHints` |
| `src/mattermost/send.ts` | 在 `sendMessageMattermost()` 入口添加调试日志（含调用栈） |

---

## 8. 日志查看

```bash
# 实时监控拦截和发送事件（去重）
tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line.strip())
        msg = d.get('0', '')
        if 'dropped group chat message without' in msg: continue
        if 'delivered reply to' in msg: continue
        if '[SEND-DEBUG] sendMessageMattermost' in msg: continue
        if any(k in msg for k in ['GROUP-CHAT-DEBUG', 'outbound sendText', 'outbound sendMedia']):
            t = d.get('time', '')[-14:-5]
            print(f'[{t}] {msg[:200]}')
    except: pass
"
```

---

## 9. 未来优化方向

1. **可配置性**：允许通过配置开关启用/禁用此前缀检查
2. **其他平台支持**：将此方案推广到 Discord、Slack 等其他群聊平台
3. **Agent 培训**：优化 prompt 确保 Agent 稳定遵守规范

---

## 10. 版本信息

- **设计日期**：2026-03-20
- **实现版本**：openclaw-mattermost v2026.2
- **作者**：Claude Agent
