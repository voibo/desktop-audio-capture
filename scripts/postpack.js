import { rmSync } from "node:fs";

function rm(path) {
  rmSync(path, {force: true});
}

rm("./lib/libsamplerate/.npmignore");
