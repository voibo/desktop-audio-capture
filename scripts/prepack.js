import { closeSync, existsSync, openSync, utimesSync } from "node:fs";

function touch(path) {
  if (existsSync(path)) {
    const now = new Date();
    utimesSync(path, now, now);
  } else {
    closeSync(openSync(path, "wx"));
  }
}

// Create an empty .npmignore file.
//
// This is intended to override the effect of the .gitignore in the libsamplerate Git submodule.
// By doing so, the issue where lib/libsamplerate/config.h.cmake is excluded from the NPM package is resolved.
touch("./lib/libsamplerate/.npmignore");
