import { desktopTurns } from "./codex-desktop-state.js";

export interface DesktopAsyncQuestion {
  id: string;
  title: string;
  options: string[];
}
export interface DesktopAsyncRequest {
  id: string;
  method: "codeaw/async-question";
  params: { questions: DesktopAsyncQuestion[] };
}

/** Use the native envelope, never interpret ordinary Markdown lists as forms. */
export function desktopQuestionReplies(input: any): { questionItemId: string; question: string; answer: string }[] {
  const text = typeof input === "string" ? input : Array.isArray(input) ? input.filter((part) => part?.type === "text").map((part) => part.text).join("\n") : "";
  const match = text.match(/^\s*<send_user_message_question_reply>\s*([\s\S]*?)\s*<\/send_user_message_question_reply>\s*$/);
  if (!match) return [];
  try {
    const replies: unknown = JSON.parse(match[1]);
    if (!Array.isArray(replies)) return [];
    return replies.filter((reply) => typeof reply?.questionItemId === "string" && typeof reply.question === "string" && typeof reply.answer === "string");
  } catch { return []; }
}

export function desktopAsyncRequests(conversation: any): DesktopAsyncRequest[] {
  const turns = desktopTurns(conversation);
  const answered = new Set<string>();
  for (const turn of turns) {
    for (const reply of desktopQuestionReplies(turn.params?.input ?? turn.input)) answered.add(reply.questionItemId);
    for (const item of turn.items ?? []) {
      if (!["userMessage", "steeringUserMessage"].includes(item.type) || ["rejected", "failed", "cancelled"].includes(item.status)) continue;
      for (const reply of desktopQuestionReplies(item.input ?? item.content ?? item.text)) answered.add(reply.questionItemId);
    }
  }
  const requests = new Map<string, DesktopAsyncRequest>();
  for (const turn of turns) {
    for (const item of turn.items ?? []) {
      const itemId = item.id ?? item.itemId;
      if (item.type !== "agentMessage" || item.delivery !== "async" || typeof itemId !== "string" || !Array.isArray(item.questions)) continue;
      const questions: DesktopAsyncQuestion[] = [];
      item.questions.forEach((question: any, index: number) => {
        const id = JSON.stringify(["request_user_input_async", itemId, index]);
        if (answered.has(id) || typeof question?.title !== "string") return;
        questions.push({ id, title: question.title, options: Array.isArray(question.options) ? question.options.filter((option: any) => typeof option === "string") : [] });
      });
      if (questions.length) requests.set(itemId, { id: itemId, method: "codeaw/async-question", params: { questions } });
    }
  }
  return [...requests.values()];
}

export function desktopAsyncReply(questions: DesktopAsyncQuestion[], response: any): { text: string; summary: string } {
  const replies = questions.map((question) => {
    const answer = response.action === "accept" ? response.content?.[question.id] : "";
    if (typeof answer !== "string" || (response.action === "accept" && !answer.trim())) throw new Error("A question answer is missing");
    return { questionItemId: question.id, question: question.title, answer: answer.trim() };
  });
  return { text: `<send_user_message_question_reply>\n${JSON.stringify(replies)}\n</send_user_message_question_reply>`,
    summary: replies.map((reply) => reply.answer || "（略過問題）").join("\n") };
}
