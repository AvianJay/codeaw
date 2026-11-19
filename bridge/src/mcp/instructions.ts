/**
 * What an agent is told about codeaw. No one channel reaches every model; each of these
 * was checked against the real agent with scripts/mcp-smoke.ts:
 * - the MCP server's `instructions`, which Claude Code adds to its system prompt;
 * - Codex ignores those and, in code mode, shows its model no tool descriptions either,
 *   so it is given the same text as developer instructions (`codexInstructionsEnvironment`);
 * - clients not known to pass `instructions` on also get `mcpToolNote` in a tool description.
 */

/** Where the agent is and who it is talking to. */
function setting(hostName: string): string {
  return `You are running through codeaw. The user talks to you from the codeaw app, usually on a phone, while you work on their computer "${hostName}".`;
}

export function mcpInstructions(hostName: string, extra?: string): string {
  const lines = [
    setting(hostName),
    "They may be away from that computer: they cannot see its screen or open its files, and they read your replies on a small screen.",
    'The tools of the "codeaw" MCP server reach them through the app:',
    "- show_files: put images and other files from this computer into the chat, instead of only naming a path.",
    "- suggest_replies: offer likely answers as tappable buttons when you end a turn with a question or clear next steps.",
    "- notify: notify their devices mid-turn when something is worth interrupting them for. Turn ends and permission requests already notify them.",
  ];
  const custom = extra?.trim();
  if (custom) lines.push("", custom);
  return lines.join("\n");
}

/**
 * The same for the end of a tool description: no tool list, since the tools are described
 * right next to it. At most `room` characters; the user's own text is cut to fit.
 */
export function mcpToolNote(hostName: string, extra: string | undefined, room: number): string {
  const note = `About this whole conversation: ${setting(hostName)}`;
  const custom = extra?.trim();
  if (!custom) return note.length <= room ? note : "";
  const left = room - note.length - 1;
  if (left >= custom.length) return `${note}\n${custom}`;
  // A few words of it would mislead more than help.
  if (left < 40) return note.length <= room ? note : "";
  return `${note}\n${custom.slice(0, left - 1).trimEnd()}…`;
}
