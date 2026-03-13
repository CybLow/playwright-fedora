#!/usr/bin/env node
// Comprehensive Playwright browser test for Fedora
// Tests all 3 engines: Chromium, Firefox, WebKit
//
// Usage:
//   node tests/test-browsers.js                 # All tests (headless + headed)
//   node tests/test-browsers.js --headless-only # Skip headed tests (for CI/Docker)
//   node tests/test-browsers.js --browser=chromium  # Single browser

const { chromium, firefox, webkit } = require("playwright");

const args = process.argv.slice(2);
const headlessOnly = args.includes("--headless-only");
const browserArg = args.find(a => a.startsWith("--browser="));
const selectedBrowser = browserArg ? browserArg.split("=")[1] : null;

const PASS = "\x1b[32mPASS\x1b[0m";
const FAIL = "\x1b[31mFAIL\x1b[0m";
const SKIP = "\x1b[33mSKIP\x1b[0m";
let passed = 0, failed = 0, skipped = 0;

const TEST_TIMEOUT = 30000; // 30s per test

async function test(name, fn) {
    try {
        await Promise.race([
            fn(),
            new Promise((_, rej) => setTimeout(() => rej(new Error("timeout after " + (TEST_TIMEOUT/1000) + "s")), TEST_TIMEOUT)),
        ]);
        console.log("  " + PASS + "  " + name);
        passed++;
    } catch (e) {
        console.log("  " + FAIL + "  " + name + " \u2014 " + e.message.split("\n")[0]);
        failed++;
    }
}

function skip(name) {
    console.log("  " + SKIP + "  " + name);
    skipped++;
}

const allBrowsers = [["Chromium", chromium], ["Firefox", firefox], ["WebKit", webkit]];
const browsers = selectedBrowser
    ? allBrowsers.filter(([n]) => n.toLowerCase() === selectedBrowser.toLowerCase())
    : allBrowsers;

(async () => {
    if (browsers.length === 0) {
        console.error("Unknown browser: " + selectedBrowser);
        process.exit(1);
    }

    for (const [bName, bType] of browsers) {
        console.log("\n\x1b[1m=== " + bName + " ===\x1b[0m");

        const browser = await bType.launch({ headless: true });

        await test("Launch headless", async () => {
            if (!browser.isConnected()) throw new Error("not connected");
        });

        await test("Navigate + read title", async () => {
            const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
            const page = await ctx.newPage();
            await page.goto("https://example.com", { timeout: 15000 });
            const t = await page.title();
            if (t !== "Example Domain") throw new Error("title: " + t);
            await ctx.close();
        });

        await test("JavaScript evaluation", async () => {
            const page = await browser.newPage();
            await page.setContent("<div id='x'>hello</div>");
            const r = await page.evaluate(() => document.getElementById("x").textContent);
            if (r !== "hello") throw new Error("got: " + r);
            await page.close();
        });

        await test("DOM manipulation (fill + click)", async () => {
            const page = await browser.newPage();
            await page.setContent(`
                <input id="inp" />
                <button onclick="document.getElementById('inp').value='clicked'">Go</button>
            `);
            await page.fill("#inp", "typed text");
            const v1 = await page.inputValue("#inp");
            if (v1 !== "typed text") throw new Error("fill: " + v1);
            await page.click("button");
            const v2 = await page.inputValue("#inp");
            if (v2 !== "clicked") throw new Error("click: " + v2);
            await page.close();
        });

        await test("Screenshot (PNG buffer)", async () => {
            const page = await browser.newPage();
            await page.setContent("<h1>Screenshot test</h1>");
            const buf = await page.screenshot();
            if (!(buf instanceof Buffer) || buf.length < 100) throw new Error("empty screenshot");
            await page.close();
        });

        await test("Multiple pages (tabs)", async () => {
            const ctx = await browser.newContext();
            const p1 = await ctx.newPage();
            const p2 = await ctx.newPage();
            await p1.setContent("<title>Page1</title>");
            await p2.setContent("<title>Page2</title>");
            if (await p1.title() !== "Page1") throw new Error("p1");
            if (await p2.title() !== "Page2") throw new Error("p2");
            await ctx.close();
        });

        await test("Context isolation (cookies)", async () => {
            const ctx1 = await browser.newContext();
            const ctx2 = await browser.newContext();
            await ctx1.addCookies([{ name: "secret", value: "123", url: "https://example.com" }]);
            const cookies = await ctx2.cookies("https://example.com");
            if (cookies.length !== 0) throw new Error("leaked cookies");
            await ctx1.close();
            await ctx2.close();
        });

        await test("Network interception (route + fulfill)", async () => {
            const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
            const page = await ctx.newPage();
            await page.route("https://example.com/api", route => {
                route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ ok: true }) });
            });
            await page.goto("https://example.com", { timeout: 15000 });
            const result = await page.evaluate(async () => {
                const r = await fetch("https://example.com/api");
                return (await r.json()).ok;
            });
            if (result !== true) throw new Error("got: " + result);
            await ctx.close();
        });

        await test("Wait for selector (dynamic content)", async () => {
            const page = await browser.newPage();
            await page.setContent(`<script>setTimeout(()=>{document.body.innerHTML='<div id="dynamic">loaded</div>'},500)</script>`);
            await page.waitForSelector("#dynamic", { timeout: 5000 });
            const text = await page.textContent("#dynamic");
            if (text !== "loaded") throw new Error("got: " + text);
            await page.close();
        });

        await test("Locator API (getByRole, getByText)", async () => {
            const page = await browser.newPage();
            await page.setContent("<button>Submit</button><p>Hello World</p>");
            if (!(await page.getByRole("button", { name: "Submit" }).isVisible())) throw new Error("btn");
            if (!(await page.getByText("Hello World").isVisible())) throw new Error("txt");
            await page.close();
        });

        await test("Viewport emulation (mobile)", async () => {
            const ctx = await browser.newContext({ viewport: { width: 375, height: 812 } });
            const page = await ctx.newPage();
            const vp = page.viewportSize();
            if (vp.width !== 375 || vp.height !== 812) throw new Error(JSON.stringify(vp));
            await ctx.close();
        });

        await test("Geolocation emulation", async () => {
            const ctx = await browser.newContext({
                geolocation: { latitude: 48.8566, longitude: 2.3522 },
                permissions: ["geolocation"],
                ignoreHTTPSErrors: true,
            });
            const page = await ctx.newPage();
            await page.goto("https://example.com", { timeout: 15000 });
            const coords = await page.evaluate(() => new Promise((res, rej) => {
                navigator.geolocation.getCurrentPosition(
                    p => res([p.coords.latitude, p.coords.longitude]),
                    e => rej(new Error("GeoError code=" + e.code))
                );
            }));
            if (Math.abs(coords[0] - 48.8566) > 0.01) throw new Error("lat: " + coords[0]);
            await ctx.close();
        });

        if (bName === "Chromium") {
            await test("PDF generation", async () => {
                const page = await browser.newPage();
                await page.setContent("<h1>PDF</h1>");
                const pdf = await page.pdf();
                if (!(pdf instanceof Buffer) || pdf.length < 500) throw new Error("empty");
                await page.close();
            });

            await test("Trace recording", async () => {
                const ctx = await browser.newContext();
                await ctx.tracing.start({ screenshots: true, snapshots: true });
                const page = await ctx.newPage();
                await page.setContent("<h1>trace</h1>");
                await ctx.tracing.stop({ path: "/tmp/pw-trace-test.zip" });
                await ctx.close();
                const fs = require("fs");
                if (!fs.existsSync("/tmp/pw-trace-test.zip")) throw new Error("no trace");
            });

            await test("HAR recording", async () => {
                const ctx = await browser.newContext({ recordHar: { path: "/tmp/pw-test.har" } });
                const page = await ctx.newPage();
                await page.setContent("<h1>har</h1>");
                await ctx.close();
                const fs = require("fs");
                if (!fs.existsSync("/tmp/pw-test.har")) throw new Error("no har");
            });

            await test("Device emulation (iPhone 13)", async () => {
                const { devices } = require("playwright");
                const ctx = await browser.newContext({ ...devices["iPhone 13"] });
                const page = await ctx.newPage();
                const vp = page.viewportSize();
                if (vp.width !== 390) throw new Error("width: " + vp.width);
                await ctx.close();
            });
        }

        await test("Video recording", async () => {
            const ctx = await browser.newContext({
                recordVideo: { dir: "/tmp/pw-videos/", size: { width: 320, height: 240 } },
            });
            const page = await ctx.newPage();
            await page.setContent("<h1>Video</h1>");
            await page.waitForTimeout(500);
            const path = await page.video().path();
            await ctx.close();
            if (!path) throw new Error("no video path");
        });

        await test("File download", async () => {
            const page = await browser.newPage();
            await page.setContent('<a href="data:text/plain,hello" download="test.txt">dl</a>');
            const [download] = await Promise.all([
                page.waitForEvent("download"),
                page.click("a"),
            ]);
            if (download.suggestedFilename() !== "test.txt") throw new Error(download.suggestedFilename());
            await page.close();
        });

        await test("Console message capture", async () => {
            const page = await browser.newPage();
            const msgs = [];
            page.on("console", msg => msgs.push(msg.text()));
            await page.setContent("<script>console.log('hello from page')</script>");
            await page.waitForTimeout(500);
            if (!msgs.some(m => m.includes("hello from page"))) throw new Error(JSON.stringify(msgs));
            await page.close();
        });

        await test("Request/response events", async () => {
            const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
            const page = await ctx.newPage();
            const urls = [];
            page.on("request", req => urls.push(req.url()));
            await page.goto("https://example.com", { timeout: 15000 });
            if (urls.length === 0) throw new Error("no requests");
            await ctx.close();
        });

        await test("Local storage", async () => {
            const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
            const page = await ctx.newPage();
            await page.goto("https://example.com", { timeout: 15000 });
            await page.evaluate(() => localStorage.setItem("key", "v"));
            const v = await page.evaluate(() => localStorage.getItem("key"));
            if (v !== "v") throw new Error("got: " + v);
            await ctx.close();
        });

        await test("iframe handling", async () => {
            const page = await browser.newPage();
            await page.setContent(`<iframe srcdoc="<h1 id='inner'>iframe</h1>"></iframe>`);
            const text = await page.frameLocator("iframe").locator("#inner").textContent();
            if (text !== "iframe") throw new Error("got: " + text);
            await page.close();
        });

        await test("Keyboard input", async () => {
            const page = await browser.newPage();
            await page.setContent("<input id='k' />");
            await page.click("#k");
            await page.keyboard.type("hello");
            const v = await page.inputValue("#k");
            if (v !== "hello") throw new Error("got: " + v);
            await page.close();
        });

        if (headlessOnly) {
            skip("Launch headed (skipped: --headless-only)");
        } else {
            await test("Launch headed (visible window)", async () => {
                const b2 = await bType.launch({ headless: false });
                const page = await b2.newPage();
                await page.setContent("<h1>Headed</h1>");
                const t = await page.textContent("h1");
                if (t !== "Headed") throw new Error(t);
                await b2.close();
            });
        }

        await browser.close();
    }

    console.log("\n\x1b[1m=== Summary ===\x1b[0m");
    console.log("  Passed:  " + passed);
    console.log("  Failed:  " + failed);
    if (skipped > 0) console.log("  Skipped: " + skipped);
    console.log("  Total:   " + (passed + failed + skipped));
    process.exit(failed > 0 ? 1 : 0);
})().catch(e => { console.error("FATAL:", e.message); process.exit(1); });
