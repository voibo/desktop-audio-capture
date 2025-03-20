import { exec } from "node:child_process";
import { exit } from "node:process";

// デバッグモードかどうかをチェック
const isDebug = process.env.DEBUG === "1" || process.argv.includes("--debug");

console.log(
  `running npm install for platform: ${process.platform} ${
    isDebug ? "(DEBUG mode)" : ""
  }`
);

const command = ["npx", "cmake-js", "compile"];

// デバッグモードの場合のみフラグを追加
if (isDebug) {
  command.push("--debug");
  // CMakeのビルドタイプをDebugに設定
  command.push("-DCMAKE_BUILD_TYPE=Debug");
}

switch (process.platform) {
  case "darwin":
    // Macでデバッグモードの場合のみSwiftフラグを設定
    if (isDebug) {
      process.env.CFLAGS = "-DDEBUG=1";
      process.env.SWIFT_FLAGS = "-DDEBUG";
    }
    break;
  case "win32":
    command.push(
      "--runtime=electron",
      "--runtime-version=30.1.0",
      "--arch=x64"
    );
    break;
  default:
    console.error(`unsupported platform ${process.platform}`);
    exit(1);
    break;
}

console.log(`Executing: ${command.join(" ")}`);

exec(command.join(" "), { env: process.env }, (error) => {
  if (error) {
    console.error(`Error in npm install: ${error}`);
    exit(1);
    return;
  }
  console.log(
    `module installed successfully${isDebug ? " in DEBUG mode" : ""}.`
  );
});
