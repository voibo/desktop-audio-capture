import { exec } from "node:child_process";
import { exit } from "node:process";

console.log(`running npm install for platform: ${process.platform}`);

const command = [
  "npx", "cmake-js", "compile",
];

switch (process.platform) {
  case "darwin":
    break;
  case "win32":
    command.push(
      "--O", "build/win32",
      "--runtime=electron",
      "--runtime-version=30.1.0",
      "--arch=x64",
    );
    break;
  default:
    console.error(`unsupported platform ${process.platform}`);
    exit(1);
    break;
}

exec(command.join(" "), (error) => {
  if (error) {
    console.error(`Error in npm install: ${error}`);
    exit(1);
    return;
  }
  console.log("module installed successfully.");
});
