/** Ordinary ACP tool calls/chunks can carry attribution to a delegating tool. */
export function parentToolCallId(update: { _meta?: Record<string, any> | null }): string | undefined {
  const id = update._meta?.claudeCode?.parentToolUseId ?? update._meta?.parentToolCallId;
  return typeof id === "string" && id.length > 0 ? id : undefined;
}
