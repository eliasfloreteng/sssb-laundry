import { describe, expect, it } from "bun:test";
import { AndroidReleases, pickRelease, type GitHubRelease } from "../src/android-release.js";
import { buildServer } from "../src/server.js";

function release(tag: string, withApk = true, extra: Partial<GitHubRelease> = {}): GitHubRelease {
  return {
    tag_name: tag,
    assets: withApk
      ? [{ name: "sssb-laundry.apk", state: "uploaded", browser_download_url: `https://github.example/${tag}/sssb-laundry.apk` }]
      : [],
    ...extra
  };
}

/** A GitHub stand-in that answers each call with the next item, counting the calls. */
function fakeGitHub(...answers: Array<GitHubRelease[] | number | Error>) {
  let calls = 0;
  const fetch = (async () => {
    const answer = answers[Math.min(calls++, answers.length - 1)]!;
    if (answer instanceof Error) throw answer;
    if (typeof answer === "number") return new Response("{}", { status: answer });
    return Response.json(answer);
  }) as unknown as typeof globalThis.fetch;
  return { fetch, calls: () => calls };
}

describe("pickRelease", () => {
  it("takes the highest version code that has the APK", () => {
    const picked = pickRelease([release("v1.1-14", false), release("v1.0-12"), release("v1.0-13"), release("v1.0-10")]);
    expect(picked).toEqual({ versionCode: 13, versionName: "1.0", apkUrl: "https://github.example/v1.0-13/sssb-laundry.apk" });
  });

  it("skips drafts, prereleases, other tags and half-uploaded assets", () => {
    const halfUploaded = release("v1.0-16");
    halfUploaded.assets[0]!.state = "starter";
    expect(
      pickRelease([
        release("v1.0-20", true, { draft: true }),
        release("v1.0-19", true, { prerelease: true }),
        release("nightly"),
        halfUploaded
      ])
    ).toBeNull();
  });
});

describe("AndroidReleases", () => {
  it("caches a lookup, and keeps the last answer when GitHub fails", async () => {
    let now = 0;
    const github = fakeGitHub([release("v1.0-12")], 500);
    const releases = new AndroidReleases({ fetch: github.fetch, now: () => now });

    expect((await releases.latest())?.versionCode).toBe(12);
    await releases.latest();
    expect(github.calls()).toBe(1);

    now += 11 * 60 * 1000;
    expect((await releases.latest())?.versionCode).toBe(12);
    expect(github.calls()).toBe(2);
  });
});

describe("routes", () => {
  it("serves the latest version and redirects the download to its APK", async () => {
    const app = buildServer({
      pushService: null,
      dibsService: null,
      androidReleases: new AndroidReleases({ fetch: fakeGitHub([release("v1.0-13"), release("v1.0-12")]).fetch })
    });
    const latest = await app.inject({ method: "GET", url: "/android/latest" });
    expect(latest.statusCode).toBe(200);
    expect(latest.json<object>()).toEqual({ versionCode: 13, versionName: "1.0" });

    const download = await app.inject({ method: "GET", url: "/android/download" });
    expect(download.statusCode).toBe(302);
    expect(download.headers.location).toBe("https://github.example/v1.0-13/sssb-laundry.apk");
    await app.close();
  });

  it("falls back to GitHub's latest link, and answers 503 for the version, with nothing known", async () => {
    const app = buildServer({
      pushService: null,
      dibsService: null,
      androidReleases: new AndroidReleases({ fetch: fakeGitHub(new Error("offline")).fetch })
    });
    expect((await app.inject({ method: "GET", url: "/android/latest" })).statusCode).toBe(503);
    const download = await app.inject({ method: "GET", url: "/android/download" });
    expect(download.headers.location).toContain("/releases/latest/download/sssb-laundry.apk");
    await app.close();
  });
});
