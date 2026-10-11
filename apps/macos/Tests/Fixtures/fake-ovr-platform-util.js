#!/usr/bin/env node
// Test double for Meta's ovr-platform-util get-access-token: the prompt code is a copy of the
// real tool's genPrompt (readline, terminal:true, output muted while the password is typed).
// Never talks to Meta. Writes what each prompt received (hex) to $FAKE_OVR_LOG; prints a fake
// token when e-mail/password/code equal $FAKE_OVR_EMAIL / $FAKE_OVR_PASSWORD / $FAKE_OVR_CODE.
"use strict";
const readline = require("readline");
const { Writable } = require("stream");
const fs = require("fs");
let muted = false;
const out = new Writable({ write(c, e, cb) { if (!muted) process.stdout.write(c, e); cb(); } });
function genPrompt(q, hidden = false, secs = 60) {
  const rl = readline.createInterface({ input: process.stdin, output: out, terminal: true });
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => { rl.close(); reject(new Error("No input provided before timeout")); }, 1000 * secs);
    muted = false;
    rl.question(q, (a) => { clearTimeout(t); rl.close(); resolve(a); });
    muted = hidden;
  });
}
const log = (k, v) => { if (process.env.FAKE_OVR_LOG) fs.appendFileSync(process.env.FAKE_OVR_LOG, `${k}=${Buffer.from(v, "utf8").toString("hex")}\n`); };
(async () => {
  process.stdout.write("Enter Meta Quest user credentials\n");
  const email = await genPrompt("Email: ");
  log("email", email);
  const pw = await genPrompt("Password <hidden>: ", true);
  log("password", pw);
  process.stdout.write("\n");
  if (!pw.trim().length) throw new Error("Password cannot be empty");
  process.stdout.write("Logging in\n");
  await new Promise((r) => setTimeout(r, 300));
  if (email !== process.env.FAKE_OVR_EMAIL || pw !== process.env.FAKE_OVR_PASSWORD) {
    process.stdout.write("Tu dirección de correo electrónico o tu contraseña son incorrectos\n");
    process.exit(1);
  }
  process.stdout.write("Two-factor authentication required.\n\n");
  const code = await genPrompt("Enter two-factor authentication code: ");
  log("code", code);
  if (code !== process.env.FAKE_OVR_CODE) { process.stdout.write("Invalid code\n"); process.exit(1); }
  process.stdout.write("Logging in\n" + "FAKETOKEN".padEnd(80, "0123456789") + "\n");
  process.exit(0);
})().catch((e) => { process.stdout.write(String(e.message) + "\n"); process.exit(1); });
