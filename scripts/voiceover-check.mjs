// Turn VoiceOver on, run Beeline's test modes, and check that VoiceOver actually spoke what Beeline announced.
// Usage: PATH=$PATH:~/Developer/tools/bin node scripts/voiceover-check.mjs [--installed | --app /path/Beeline.app]
// Needs ~/Developer/tools/guidepup and VoiceOver's "Allow VoiceOver to be controlled with AppleScript".
// It takes over the keyboard and speakers: run it only when nobody is using the Mac.
import { createRequire } from "node:module";
import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";

const require = createRequire(join(homedir(), "Developer/tools/guidepup/package.json"));
const { voiceOver } = require("@guidepup/guidepup");

const args = process.argv.slice(2);
let app = resolve("build/Beeline.app");
if (args.includes("--installed")) app = join(homedir(), "Applications/Beeline.app");
const at = args.indexOf("--app");
if (at >= 0) app = resolve(args[at + 1]);
const binary = join(app, "Contents/MacOS/Beeline");
if (!existsSync(binary)) { console.error(`No app at ${app}`); process.exit(2); }

const out = mkdtempSync(join(tmpdir(), "beeline-voiceover-check."));
const phrases = ["open TextEdit", "turn wi-fi off"];
const scenarios = phrases.map((p) => ({ name: `voice: ${p}`, demo: "voice", phrase: p }));

const words = (s) => s.toLowerCase().replace(/[^a-z0-9 ]+/g, " ").split(/\s+/).filter(Boolean);
// VoiceOver may cut a phrase short or join it with others, so match by words in order.
const spoken = (want, log) => {
  const w = words(want).join(" ");
  return log.some((line) => words(line).join(" ").includes(w));
};

function runScenario(s, index) {
  const log = join(out, `${index}.jsonl`);
  const env = { ...process.env, BEELINE_DEMO: s.demo, BEELINE_DEMO_LOG: log, BEELINE_VOICE_RUN: "0" };
  if (s.phrase) {
    const file = join(out, `${index}.aiff`);
    execFileSync("say", ["-o", file, "--", s.phrase]);
    env.BEELINE_VOICE_FILE = file;
  }
  return new Promise((done) => {
    const child = spawn(binary, [], { env, stdio: "ignore" });
    const timer = setTimeout(() => child.kill(), 60000);
    child.on("exit", () => { clearTimeout(timer); done(log); });
  });
}

const results = [];
let failed = false;
try {
  await voiceOver.start();
  for (const [i, s] of scenarios.entries()) {
    // Guidepup's phrase log only covers its own commands, so poll what VoiceOver last said instead.
    const heard = [];
    let polling = true;
    const poll = (async () => {
      while (polling) {
        try {
          const phrase = await voiceOver.lastSpokenPhrase();
          if (phrase && phrase !== heard.at(-1)) heard.push(phrase);
        } catch {}
        await new Promise((r) => setTimeout(r, 100));
      }
    })();
    const logPath = await runScenario(s, i);
    await new Promise((r) => setTimeout(r, 2500)); // let VoiceOver finish the last announcement
    polling = false;
    await poll;
    const events = existsSync(logPath)
      ? readFileSync(logPath, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
    const announced = events.filter((e) => e.event === "announcement").map((e) => e.text);
    const result = events.find((e) => e.event === "result");
    const missed = announced.filter((a) => !spoken(a, heard));
    const pass = Boolean(result?.pass) && announced.length > 0 && missed.length === 0;
    failed ||= !pass;
    results.push({ scenario: s.name, pass, beeline: result?.why ?? "no result", announced, heard, missed });
    console.log(`${pass ? "PASS" : "FAIL"} ${s.name}: ${announced.length} announced, ${missed.length} not spoken`);
    for (const m of missed) console.log(`  not spoken: ${m}`);
    if (!announced.length) console.log("  Beeline announced nothing");
  }
} catch (e) {
  failed = true;
  console.log(`FAIL: ${e.message}`);
} finally {
  try { await voiceOver.stop(); } catch {}
}
writeFileSync(join(out, "report.json"), JSON.stringify(results, null, 2));
console.log(`Report: ${join(out, "report.json")}`);
process.exit(failed ? 1 : 0);
