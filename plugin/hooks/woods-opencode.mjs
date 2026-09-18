// OpenCode 1.18.27 tool.execute.after adapter. Keep callback metadata private:
// only the worktree and affected paths cross into the shared refresh runner.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const runner = fileURLToPath(new URL("./woods-refresh.sh", import.meta.url));
const enabled = () => process.env.WOODS_HOOKS_ENABLED === "1" && process.env.WOODS_HOOKS_DISABLED !== "1";
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const pathString = (value) => typeof value === "string" && value.length > 0 && !value.includes("\0");

function eventsFor(input, output) {
  if (!object(input) || !object(output) || !object(output.metadata)) throw new Error("invalid event");
  const metadata = output.metadata;
  if (input.tool === "apply_patch") {
    if (!Array.isArray(metadata.files) || !metadata.files.length || metadata.files.length > 1000) throw new Error("missing file metadata");
    return metadata.files.flatMap((file) => {
      if (!object(file) || !pathString(file.filePath)) throw new Error("invalid file metadata");
      if (file.type === "move") {
        if (!pathString(file.movePath)) throw new Error("missing move target");
        return [{ path: file.filePath, operation: "delete" }, { path: file.movePath, operation: "add" }];
      }
      if (!["add", "update", "delete"].includes(file.type)) throw new Error("unknown file operation");
      return [{ path: file.filePath, operation: file.type }];
    });
  }
  if (input.tool === "write") {
    if (!pathString(metadata.filepath) || typeof metadata.exists !== "boolean") throw new Error("invalid write metadata");
    return [{ path: metadata.filepath, operation: metadata.exists ? "update" : "add" }];
  }
  if (input.tool === "edit") {
    if (!object(metadata.filediff) || !pathString(metadata.filediff.file)) throw new Error("invalid edit metadata");
    return [{ path: metadata.filediff.file, operation: "update" }];
  }
  throw new Error("unsupported tool");
}

export default async function WoodsHooks({ directory, worktree }) {
  return {
    "tool.execute.after": async (input, output) => {
      if (!enabled() || !["apply_patch", "write", "edit"].includes(input?.tool)) return;
      try {
        if (!pathString(directory) || !pathString(worktree) || !path.isAbsolute(directory) || !path.isAbsolute(worktree)) {
          throw new Error("invalid project context");
        }
        const relative = path.relative(worktree, directory);
        if (relative === ".." || relative.startsWith("../") || path.isAbsolute(relative)) throw new Error("foreign project");
        const payload = JSON.stringify({ version: 1, client: "opencode", root: directory, events: eventsFor(input, output) });
        if (Buffer.byteLength(payload) > 49_152) throw new Error("event too large");
        // The shared runner durably queues and owns its own deadline. Tool
        // completion only hands off the event; it does not claim refresh success.
        await new Promise((resolve, reject) => {
          const child = spawn("bash", [runner, "opencode"], {
            cwd: directory, detached: true, stdio: ["pipe", "ignore", "inherit"],
          });
          child.once("error", reject);
          child.stdin.once("error", reject);
          child.stdin.end(payload, () => { child.unref(); resolve(); });
        });
      } catch {
        console.error("[Woods hooks] Unsupported, malformed or undeliverable OpenCode edit event; refresh not confirmed.");
      }
    },
  };
}
