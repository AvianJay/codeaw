import * as acp from "@agentclientprotocol/sdk";

export type AgentAuthMethod = Pick<acp.AuthMethod, "id" | "name" | "description">;

/** Only protocol-driven methods are supported; never send launch env or metadata to a device. */
export function agentAuthMethods(methods: acp.AuthMethod[] | null | undefined): AgentAuthMethod[] {
  return (methods ?? []).filter((method) => {
    const type = (method as { type?: unknown }).type;
    return type === undefined || type === "agent";
  }).map(({ id, name, description }) => ({ id, name, ...(description ? { description } : {}) }));
}

/** Auth errors can contain local paths and provider configuration; send actionable metadata instead. */
export function agentAuthRequired(agentId: string, authMethods: AgentAuthMethod[], authFailed = false): acp.RequestError {
  return acp.RequestError.authRequired({ codeaw: { agentId, authMethods, ...(authFailed ? { authFailed: true } : {}) } });
}
