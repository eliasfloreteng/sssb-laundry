import type { LoggerLike } from "./aptus-client.js";

/** The newest Android build that can be downloaded, as the app compares it with its own. */
export interface AndroidRelease {
  versionCode: number;
  versionName: string;
  /** The APK itself, on GitHub. */
  apkUrl: string;
}

/** The subset of GitHub's release document this reads. */
export interface GitHubRelease {
  tag_name: string;
  draft?: boolean;
  prerelease?: boolean;
  assets: { name: string; state?: string; browser_download_url: string }[];
}

export const APK_NAME = "sssb-laundry.apk";
const RELEASES_URL = "https://api.github.com/repos/eliasfloreteng/sssb-laundry/releases?per_page=10";

/** Long enough to stay far below GitHub's 60 anonymous requests an hour. */
const CACHE_MS = 10 * 60 * 1000;
/** After a failed lookup, how long before the next one. */
const RETRY_MS = 60 * 1000;

/** bump-build.yml tags every build `v<versionName>-<versionCode>`. */
const TAG = /^v(.+)-(\d+)$/;

/**
 * The newest release that already carries the APK. bump-build.yml creates the
 * release minutes before android-release.yml attaches the APK, so "latest" alone
 * would briefly point at a release with nothing to download.
 */
export function pickRelease(releases: GitHubRelease[]): AndroidRelease | null {
  let best: AndroidRelease | null = null;
  for (const release of releases) {
    if (release.draft || release.prerelease) continue;
    const match = TAG.exec(release.tag_name);
    const apk = release.assets.find((a) => a.name === APK_NAME && (a.state ?? "uploaded") === "uploaded");
    if (!match || !apk) continue;
    const versionCode = Number(match[2]);
    if (!best || versionCode > best.versionCode) {
      best = { versionCode, versionName: match[1]!, apkUrl: apk.browser_download_url };
    }
  }
  return best;
}

/** Looks the newest APK up on GitHub, cached so neither the app nor the page waits on it. */
export class AndroidReleases {
  private readonly fetch: typeof globalThis.fetch;
  private readonly logger?: LoggerLike;
  private readonly now: () => number;
  private cached?: { release: AndroidRelease | null; until: number };
  private pending?: Promise<AndroidRelease | null>;

  constructor(options: { fetch?: typeof globalThis.fetch; logger?: LoggerLike; now?: () => number } = {}) {
    this.fetch = options.fetch ?? globalThis.fetch;
    this.logger = options.logger;
    this.now = options.now ?? Date.now;
  }

  /** `null` only when GitHub has never answered with a usable release. */
  latest(): Promise<AndroidRelease | null> {
    if (this.cached && this.now() < this.cached.until) return Promise.resolve(this.cached.release);
    this.pending ??= this.lookUp().finally(() => {
      this.pending = undefined;
    });
    return this.pending;
  }

  private async lookUp(): Promise<AndroidRelease | null> {
    try {
      const response = await this.fetch(RELEASES_URL, {
        headers: { accept: "application/vnd.github+json", "user-agent": "sssb-laundry-api" },
        signal: AbortSignal.timeout(10_000)
      });
      if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
      const release = pickRelease((await response.json()) as GitHubRelease[]);
      this.cached = { release, until: this.now() + CACHE_MS };
      return release;
    } catch (error) {
      this.logger?.warn?.({ err: error instanceof Error ? error.message : String(error) }, "Android release lookup failed");
      // Keep serving what was known; an update a few minutes late is no harm.
      const release = this.cached?.release ?? null;
      this.cached = { release, until: this.now() + RETRY_MS };
      return release;
    }
  }
}
