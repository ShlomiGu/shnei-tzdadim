// Copies the live web app (../site, or the files already in www) into www/ for the native shells.
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
const src = process.env.SITE_DIR || "../shnei-tzdadim/site";
if (existsSync(src)) {
  mkdirSync("www", { recursive: true });
  for (const f of ["index.html", "venues.json", "manifest.json", "privacy.html", "terms.html", "contact.html", "og.png", "icon-180.png", "icon-192.png", "icon-512.png"])
    if (existsSync(`${src}/${f}`)) cpSync(`${src}/${f}`, `www/${f}`);
}
// Capacitor injects window.Capacitor; nothing else to change: the page detects it at runtime.
let html = readFileSync("www/index.html", "utf8");
if (!html.includes("capacitor-native")) {
  html = html.replace("<head>", '<head>\n<meta name="capacitor-native" content="1">');
  writeFileSync("www/index.html", html);
}
console.log("www/ ready");
