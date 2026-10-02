import fs from "node:fs";

fs.cpSync(new URL("../src/assets/", import.meta.url), new URL("../dist/assets/", import.meta.url), { recursive: true });
