import fs from "node:fs/promises";
import path from "node:path";

const RUN_DIRECTORY = /^run-(\d+)-[A-Za-z0-9_-]+$/;

function processAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

/** Only bridge-owned extraction directories are eligible for automatic removal. */
export class AgentTempDirectory {
  private constructor(readonly directory: string, private readonly root: string) {}

  static async create(root: string): Promise<AgentTempDirectory> {
    root = path.resolve(root);
    await fs.mkdir(root, { recursive: true });
    for (const entry of await fs.readdir(root, { withFileTypes: true })) {
      const owner = entry.name.match(RUN_DIRECTORY);
      if (!entry.isDirectory() || !owner || processAlive(Number(owner[1]))) continue;
      const directory = path.join(root, entry.name);
      try {
        const lease: unknown = JSON.parse(await fs.readFile(path.join(directory, "owner.json"), "utf8"));
        const pid = (lease as { pid?: unknown } | null)?.pid;
        if (typeof pid !== "number" || !Number.isSafeInteger(pid) || pid <= 0 || processAlive(pid)) continue;
        await new AgentTempDirectory(directory, root).dispose();
      } catch {
        // Unrecognized or locked directories are left alone.
      }
    }
    return new AgentTempDirectory(await fs.mkdtemp(path.join(root, "run-" + process.pid + "-")), root);
  }

  environment(env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
    const result = { ...env };
    // Windows environment names are case insensitive, including in cross-spawn.
    for (const key of Object.keys(result)) if (["TMP", "TEMP"].includes(key.toUpperCase())) delete result[key];
    return { ...result, TMP: this.directory, TEMP: this.directory };
  }

  async recordProcess(pid: number): Promise<void> {
    await fs.writeFile(path.join(this.directory, "owner.json"), JSON.stringify({ pid }));
  }

  async dispose(): Promise<void> {
    const target = path.resolve(this.directory);
    if (path.dirname(target) !== this.root || !RUN_DIRECTORY.test(path.basename(target))) throw new Error("Unsafe agent temp directory");
    try {
      const info = await fs.lstat(target);
      if (!info.isDirectory() || info.isSymbolicLink()) return;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    await fs.rm(target, { recursive: true, force: true, maxRetries: 5, retryDelay: 150 });
  }
}
