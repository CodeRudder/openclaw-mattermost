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
dispatchReplyFromConfig() 调用 dispatcher.sendFinalReply(payload)
    ↓
normalizeReplyPayload() 处理（原逻辑：仅移除 NO_REPLY）
    ↓
deliver() 发送到 Mattermost
```

#### 关键代码位置

| 文件 | 功能 |
|------|------|
| `openclaw/src/agents/pi-embedded-utils.ts` | `extractAssistantText()` 提取 agent text 输出 |
| `openclaw/src/agents/pi-embedded-runner/run/payloads.ts` | `buildEmbeddedRunPayloads()` 转换为 payload |
| `openclaw/src/auto-reply/reply/normalize-reply.ts` | `normalizeReplyPayload()` 消息规范化处理 |
| `openclaw/src/auto-reply/tokens.ts` | 定义消息标记常量 |

#### 核心问题

openclaw 的默认行为是将 Agent 的**所有 text 输出**自动转换为回复消息发送。这是设计意图，但在群聊场景下需要更精细的控制。

---

## 2. 解决方案

### 2.1 方案概述

采用 **显式前缀标记** 方案：Agent 在需要发送群聊消息时，必须在消息开头添加 `[GROUP-CHAT]` 标记。没有此标记的消息会被系统拦截，不会发送到群聊。

### 2.2 方案优势

1. **显式控制**：Agent 必须明确标记要发送的消息
2. **安全拦截**：任何意外输出（无标记）都会被丢弃
3. **不修改内核架构**：仅在消息规范化层面添加检查
4. **向后兼容**：私聊场景不受影响

### 2.3 方案对比

| 方案 | 优点 | 缺点 |
|------|------|------|
| **[GROUP-CHAT] 前缀方案** | 显式控制、安全拦截、灵活 | Agent 需要遵守约定 |
| 完全禁止群聊自动发送 | 最安全 | Agent 无法发送任何 text，必须用 tool |
| 仅依赖 NO_REPLY | 简单 | Agent 输出分析+NO_REPLY 时仍会泄露内容 |

---

## 3. 实现细节

### 3.1 新增常量

**文件**：`openclaw/src/auto-reply/tokens.ts`

```typescript
export const GROUP_CHAT_REPLY_PREFIX = "[GROUP-CHAT]";
```

### 3.2 normalizeReplyPayload 修改

**文件**：`openclaw/src/auto-reply/reply/normalize-reply.ts`

**新增选项**：
```typescript
export type NormalizeReplyOptions = {
  // ... 其他选项
  /** When true, only messages with GROUP_CHAT_REPLY_PREFIX will be delivered.
   * The prefix is stripped before delivery. Messages without the prefix are dropped. */
  isGroupChat?: boolean;
};
```

**处理逻辑**：
```typescript
// Group chat prefix check: only messages with [GROUP-CHAT] prefix are delivered
if (opts.isGroupChat && text) {
  if (text.startsWith(GROUP_CHAT_REPLY_PREFIX)) {
    // Strip the prefix and continue
    text = text.slice(GROUP_CHAT_REPLY_PREFIX.length).trim();
  } else {
    // No prefix - drop the message (prevent accidental content leakage to group chats)
    if (!hasMedia && !hasChannelData) {
      opts.onSkip?.("silent");
      return null;
    }
    // If there's media, keep it but clear the text
    text = "";
  }
}
```

### 3.3 ReplyDispatcher 修改

**文件**：`openclaw/src/auto-reply/reply/reply-dispatcher.ts`

**新增选项**：
```typescript
export type ReplyDispatcherOptions = {
  // ... 其他选项
  /** When true, only messages with GROUP_CHAT_REPLY_PREFIX will be delivered. */
  isGroupChat?: boolean;
};
```

### 3.4 Mattermost 插件修改

**文件**：`openclaw-mattermost/src/mattermost/monitor.ts`

**传递 isGroupChat 参数**：
```typescript
const { dispatcher, replyOptions, markDispatchIdle } =
  core.channel.reply.createReplyDispatcherWithTyping({
    ...prefixOptions,
    humanDelay: core.channel.reply.resolveHumanDelayConfig(cfg, route.agentId),
    typingCallbacks,
    isGroupChat: kind !== "direct",  // 新增
    deliver: async (payload: ReplyPayload) => {
      // ...
    },
  });
```

**更新群聊提示词**：
```typescript
const groupHints = isQueuedMessage
  ? `\n\n[群聊消息处理提示] 这是队列合并消息。忽略其它Agent的分析内容，只关注@你的原始消息。快速判断是否需要回复。不需要回复时仅输出NO_REPLY。需要回复时在消息开头添加[GROUP-CHAT]标记，然后发送消息内容。\n\n`
  : `[群聊消息处理提示] 忽略消息中其它Agent的分析过程，只关注与你相关的@消息或问题。不需要回复时仅输出NO_REPLY。需要回复时在消息开头添加[GROUP-CHAT]标记，然后发送消息内容。\n\n`;
```

---

## 4. 工作流程

### 4.1 群聊消息处理流程

```
群聊消息到达
    ↓
Agent 处理消息
    ↓
Agent 输出判断：
    ├─ 需要回复 → 输出 "[GROUP-CHAT] 消息内容"
    │       ↓
    │   normalizeReplyPayload 检测到前缀
    │       ↓
    │   删除前缀 → 发送消息到群聊
    │
    └─ 不需要回复 → 输出 "NO_REPLY" 或其他内容
            ↓
        normalizeReplyPayload 检测无前缀
            ↓
        丢弃消息（不发送）
```

### 4.2 私聊消息处理流程

私聊场景不受影响，`isGroupChat: false`，跳过前缀检查：

```
私聊消息到达
    ↓
Agent 处理消息
    ↓
Agent 输出任何内容
    ↓
normalizeReplyPayload (isGroupChat: false)
    ↓
正常处理并发送
```

---

## 5. Agent 行为规范

### 5.1 群聊场景

**需要发送消息时**：
```
[GROUP-CHAT] 收到，我会立即处理这个问题。
```

**不需要发送消息时**：
```
NO_REPLY
```
或
```
（任何不带 [GROUP-CHAT] 前缀的内容，将被丢弃）
```

### 5.2 私聊场景

无需特殊处理，正常输出即可。

---

## 6. 文件修改清单

| 文件 | 修改内容 |
|------|----------|
| `openclaw/src/auto-reply/tokens.ts` | 新增 `GROUP_CHAT_REPLY_PREFIX` 常量 |
| `openclaw/src/auto-reply/reply/normalize-reply.ts` | 新增 `isGroupChat` 选项和前缀检查逻辑 |
| `openclaw/src/auto-reply/reply/reply-dispatcher.ts` | 新增 `isGroupChat` 选项传递 |
| `openclaw-mattermost/src/mattermost/monitor.ts` | 传递 `isGroupChat` 参数，更新群聊提示词 |

---

## 7. 测试验证

### 7.1 测试场景

1. **群聊 - 需要回复**
   - Agent 输出：`[GROUP-CHAT] 测试消息`
   - 预期：群聊收到 `测试消息`

2. **群聊 - 不需要回复**
   - Agent 输出：`NO_REPLY`
   - 预期：群聊不收到任何消息

3. **群聊 - 意外输出**
   - Agent 输出：`用户发来消息...分析...NO_REPLY`
   - 预期：群聊不收到任何消息（无前缀，被丢弃）

4. **私聊 - 正常输出**
   - Agent 输出：`收到你的消息`
   - 预期：私聊收到 `收到你的消息`

### 7.2 验证方法

```bash
# 查看会话日志
tail -f ~/.openclaw/agents/project-manager/sessions/*.jsonl

# 查看 gateway 日志
openclaw logs
```

---

## 8. 未来优化方向

1. **可配置性**：允许通过配置开关启用/禁用此前缀检查
2. **其他平台支持**：将此方案推广到 Discord、Slack 等其他群聊平台
3. **Agent 培训**：优化 prompt 确保 Agent 稳定遵守规范

---

## 9. 版本信息

- **设计日期**：2026-03-20
- **实现版本**：openclaw v2026.2
- **作者**：Claude Agent
