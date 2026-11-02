package se.floreteng.sssblaundry.data

import java.net.URI

/**
 * The one link the app hands out, and everything that reads one back:
 * `https://sssb-laundry.eliasf.se/invite#1234-5678-901`.
 *
 * The object number rides in the *fragment*: no browser sends one to a server,
 * and the number is a credential with no business in an access log. The path is
 * spelled again in AndroidManifest.xml and in the iOS app; change them together.
 */
object InviteLink {
    const val PATH = "/invite"

    /** The link to share. Without an object number it is just the landing page. */
    fun url(objectId: String?): String {
        val trimmed = objectId?.trim().orEmpty()
        if (trimmed.isEmpty()) return Config.BASE_URL
        return "${Config.BASE_URL}$PATH#$trimmed"
    }

    /** The object number an incoming link carries, if it is ours and carries one. */
    fun objectIdFromUrl(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        val base = URI(Config.BASE_URL)
        if (uri.host != base.host || uri.path != PATH) return null
        val fragment = uri.rawFragment ?: return null
        return objectIdFromPasted(fragment)
    }

    /**
     * Reads an object number out of whatever was pasted — an invite link, or the
     * bare number. Anything not a digit or hyphen separates candidates, so the
     * hyphen in the host name never confuses the number in the fragment.
     */
    fun objectIdFromPasted(text: String): String? =
        text.split(Regex("[^0-9-]+")).firstOrNull(::isObjectNumber)

    /** Aptus's own shape, `1234-5678-901`. Strict on purpose. */
    private fun isObjectNumber(candidate: String): Boolean {
        val parts = candidate.split("-")
        return parts.map { it.length } == listOf(4, 4, 3) && parts.all { part -> part.all(Char::isDigit) }
    }
}
