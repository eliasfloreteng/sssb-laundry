package se.floreteng.sssblaundry.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.coroutines.executeAsync
import java.io.IOException
import java.io.InterruptedIOException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.cancellation.CancellationException

object Config {
    const val BASE_URL = "https://sssb-laundry.eliasf.se"
}

/**
 * The laundry API. Sign-in is the object number, sent as `X-Object-Id` on every
 * request; it is username *and* password upstream, so it is never logged.
 */
class ApiClient(
    private val objectId: () -> String?,
    /** This phone's FCM token, if it has one: lets the server skip it when announcing its own bookings. */
    private val deviceToken: () -> String? = { null },
    private val baseUrl: HttpUrl = Config.BASE_URL.toHttpUrl(),
    private val http: OkHttpClient = defaultClient,
) {
    suspend fun getWeek(date: String): WeekResponse =
        send(request(url { addPathSegment("timeslots").addQueryParameter("date", date) }, "GET"))

    suspend fun book(timeslotId: String, groupIds: List<Int>): ActionResponse =
        action(timeslotId, "book", "POST", groupIds)

    suspend fun cancel(timeslotId: String, groupIds: List<Int>): ActionResponse =
        action(timeslotId, "cancel", "POST", groupIds)

    /** Joins the line for groups somebody else holds, or free ones past the limit. */
    suspend fun callDibs(timeslotId: String, groupIds: List<Int>): DibsResponse =
        action(timeslotId, "dibs", "POST", groupIds)

    suspend fun dropDibs(timeslotId: String, groupIds: List<Int>): OkResponse =
        action(timeslotId, "dibs", "DELETE", groupIds)

    /** The whole order, most wanted first. */
    suspend fun setDibsPriority(timeslotIds: List<String>): OkResponse =
        send(
            request(
                url { addPathSegments("dibs/priority") },
                "PUT",
                buildJsonObject { putJsonArray("timeslotIds") { timeslotIds.forEach { add(it) } } },
            ),
        )

    /** Leaves every line at once — the dibs setting was turned off. */
    suspend fun dropAllDibs(): OkResponse = send(request(url { addPathSegment("dibs") }, "DELETE"))

    /** `context` is shown beside the message; the server forwards only a hash of the object id. */
    suspend fun sendFeedback(message: String, context: Map<String, String>): OkResponse =
        send(
            request(
                url { addPathSegment("feedback") },
                "POST",
                buildJsonObject {
                    put("message", message)
                    putJsonObject("context") { context.forEach { (k, v) -> put(k, v) } }
                },
            ),
        )

    /**
     * Registers this phone for pushes about the signed-in object number. An
     * idempotent upsert keyed on the token, so it is safe to repeat. A server
     * without push answers 503 `PUSH_DISABLED`, as it does for the demo number.
     */
    suspend fun registerDevice(
        deviceToken: String,
        enabled: Boolean,
        alertMinutes: Int?,
        secondAlertMinutes: Int?,
    ): OkResponse = send(
        request(
            url { addPathSegments("notifications/device") },
            "PUT",
            buildJsonObject {
                put("platform", PLATFORM)
                put("deviceToken", deviceToken)
                put("enabled", enabled)
                put("alertMinutes", alertMinutes)
                put("secondAlertMinutes", secondAlertMinutes)
                put("pushVersion", PUSH_VERSION)
            },
        ),
    )

    suspend fun deregisterDevice(deviceToken: String): OkResponse = send(
        request(
            url { addPathSegments("notifications/device") },
            "DELETE",
            buildJsonObject {
                put("platform", PLATFORM)
                put("deviceToken", deviceToken)
            },
        ),
    )

    /** The newest APK. Asked signed out too, so it goes without the object number. */
    suspend fun latestAndroidRelease(): AndroidRelease = send(
        Request.Builder()
            .url(url { addPathSegments("android/latest") })
            .header("Accept", "application/json")
            .build(),
    )

    /** The same client speaking for another object number — to deregister the one being left. */
    fun forObjectId(id: String): ApiClient = ApiClient({ id }, deviceToken, baseUrl, http)

    private suspend inline fun <reified T> action(
        timeslotId: String,
        path: String,
        method: String,
        groupIds: List<Int>,
    ): T {
        val request = request(
            url { addPathSegment("timeslots").addPathSegment(timeslotId).addPathSegment(path) },
            method,
            buildJsonObject { putJsonArray("groupIds") { groupIds.forEach { add(it) } } },
        )
        val token = deviceToken()
        return send(if (token == null) request else request.newBuilder().header("X-Device-Token", token).build())
    }

    private inline fun url(build: HttpUrl.Builder.() -> Unit): HttpUrl = baseUrl.newBuilder().apply(build).build()

    private fun request(url: HttpUrl, method: String, body: JsonObject? = null): Request {
        val id = objectId()
        if (id.isNullOrEmpty()) throw ApiError.local("MISSING_OBJECT_ID", "Object id is required.")
        val requestBody: RequestBody? = body?.toString()?.toRequestBody(jsonType)
        return Request.Builder()
            .url(url)
            .method(method, requestBody)
            .header("X-Object-Id", id)
            .header("Accept", "application/json")
            .build()
    }

    private suspend inline fun <reified T> send(request: Request): T {
        val (code, text) = try {
            http.newCall(request).executeAsync().use { response ->
                response.code to withContext(Dispatchers.IO) { response.body.string() }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            throw networkError(e)
        }
        if (code !in 200..299) {
            val envelope = runCatching { json.decodeFromString<ApiErrorEnvelope>(text) }.getOrNull()
            throw envelope?.error ?: ApiError.local(if (code >= 500) "SERVICE_ERROR" else "UNKNOWN_ERROR")
        }
        return try {
            json.decodeFromString<T>(text)
        } catch (e: Exception) {
            throw ApiError.local("BAD_RESPONSE")
        }
    }

    private fun networkError(e: IOException): ApiError = when (e) {
        is UnknownHostException -> ApiError.local("NO_INTERNET")
        is InterruptedIOException -> ApiError.local("TIMEOUT")
        else -> ApiError.local("NETWORK_ERROR")
    }

    companion object {
        val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            coerceInputValues = true
        }
        private const val PLATFORM = "android"
        private val jsonType = "application/json".toMediaType()
        private val defaultClient = OkHttpClient.Builder()
            .callTimeout(60, TimeUnit.SECONDS)
            .build()
    }
}
