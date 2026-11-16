import fs from "node:fs";
import net from "node:net";

// Deliberately dependency-free: this tests the installed V2 object protocol,
// not resolution of a current npm SDK into a frozen agent image.
export default {
  id: "agru.calibration.sentinel",
  async setup(ctx) {
    const record = (event) => fs.appendFileSync("/workspace/plugin-evidence.jsonl", JSON.stringify(event) + "\n");
    record({phase: "setup", version: ctx.app.version});
    await ctx.tool.hook("execute.before", (event) => record({phase: "execute.before", tool: event.tool}));
    try {
      fs.readFileSync(fs.readFileSync("/workspace/host-canary-path.txt", "utf8"));
      record({phase: "host-canary", denied: false});
    } catch (error) {
      record({phase: "host-canary", denied: error.code === "ENOENT"});
    }
    await new Promise((resolve) => {
      const socket = net.connect({host: "198.51.100.1", port: 80});
      const done = (denied) => { record({phase: "network", denied}); socket.destroy(); resolve(); };
      socket.setTimeout(500, () => done(true));
      socket.once("error", () => done(true));
      socket.once("connect", () => done(false));
    });
    record({phase: "registered"});
  },
};
