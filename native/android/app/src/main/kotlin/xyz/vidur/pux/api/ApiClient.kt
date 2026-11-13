package xyz.vidur.pux.api

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.withContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject
import xyz.vidur.pux.model.ServerHealth
import xyz.vidur.pux.model.ServerHealthState
import xyz.vidur.pux.model.TestCode
import xyz.vidur.pux.storage.RecordStore
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

open class RecordNotFoundException : Exception("Relay not found on the server")
open class TooManyDevicesException : Exception("This relay already has the maximum number of devices")
open class RateLimitedException : Exception("The server is rate limiting requests")
open class NoDevicesException : Exception("No device is registered on this relay yet")
open class ApiException(message: String) : Exception(message)
class RegistrationRejectedException : ApiException("Device registration was rejected by the server")

data class CreateRecordResult(
    val recordId: String,
    val inboxAddress: String
)

open class ApiClient(
    private val recordStore: RecordStore,
    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build(),
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO
) {
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    /**
     * Creates a new relay record on the server using [publicKey].
     * POST /api/v1/records
     */
    suspend fun createRecord(publicKey: String): CreateRecordResult = withContext(ioDispatcher) {
        val url = "${recordStore.serverUrl}/api/v1/records"
        val bodyJson = JSONObject().apply {
            put("public_key", publicKey)
        }
        val request = Request.Builder()
            .url(url)
            .post(bodyJson.toString().toRequestBody(jsonMediaType))
            .build()

        execute(request, coroutineContext).use { response ->
            checkResponse(response, "Record creation")
            val bodyStr = response.body?.string() ?: ""
            val json = JSONObject(bodyStr)
            val recordId = json.optString("record_id")
            val inboxAddress = json.optString("inbox_address")
            if (recordId.isEmpty() || inboxAddress.isEmpty()) {
                throw ApiException("Record creation returned an incomplete response")
            }
            CreateRecordResult(recordId, inboxAddress)
        }
    }

    /**
     * Registers this device's push token with the server.
     * POST /api/v1/record/devices
     */
    suspend fun registerDevice(
        recordId: String,
        pushToken: String,
        platform: String = "fcm",
        replacesDeviceId: String? = null
    ): String? = withContext(ioDispatcher) {
        val url = "${recordStore.serverUrl}/api/v1/record/devices"
        val bodyJson = JSONObject().apply {
            put("push_token", pushToken)
            put("platform", platform)
            if (!replacesDeviceId.isNullOrEmpty()) {
                put("device_id", replacesDeviceId)
            }
        }
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $recordId")
            .post(bodyJson.toString().toRequestBody(jsonMediaType))
            .build()

        execute(request, coroutineContext).use { response ->
            if (response.code == 401 || response.code == 404) {
                throw RecordNotFoundException()
            }
            if (response.code == 422) {
                if (errorCode(response) == "too_many_devices") throw TooManyDevicesException()
                throw RegistrationRejectedException()
            }
            checkResponse(response, "Device registration")
            val json = decodeObject(response)
            json?.optString("device_id")?.takeIf { it.isNotEmpty() }
        }
    }

    /**
     * Removes one device from the record.
     * DELETE /api/v1/record/devices/$deviceId
     * A device or record the server no longer knows counts as removed.
     */
    suspend fun deleteDevice(recordId: String, deviceId: String): Unit = withContext(ioDispatcher) {
        val url = "${recordStore.serverUrl}/api/v1/record/devices/$deviceId"
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $recordId")
            .delete()
            .build()

        execute(request, coroutineContext).use { response ->
            if (response.code == 401 || response.code == 404) return@withContext
            checkResponse(response, "Device removal")
        }
    }

    /**
     * Deletes the record with all its devices.
     * DELETE /api/v1/record
     * A record the server no longer knows counts as deleted.
     */
    suspend fun deleteRecord(recordId: String): Unit = withContext(ioDispatcher) {
        val url = "${recordStore.serverUrl}/api/v1/record"
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $recordId")
            .delete()
            .build()

        execute(request, coroutineContext).use { response ->
            if (response.code == 401 || response.code == 404) return@withContext
            checkResponse(response, "Relay deletion")
        }
    }

    /**
     * Sends a test code to all devices on the relay.
     * POST /api/v1/record/test
     */
    suspend fun sendTestCode(recordId: String): TestCode = withContext(ioDispatcher) {
        val url = "${recordStore.serverUrl}/api/v1/record/test"
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $recordId")
            .post("{}".toRequestBody(jsonMediaType))
            .build()

        execute(request, coroutineContext).use { response ->
            if (response.code == 401 || response.code == 404) {
                throw RecordNotFoundException()
            }
            if (response.code == 409 && errorCode(response) == "no_devices") {
                throw NoDevicesException()
            }
            checkResponse(response, "Test code")
            val json = decodeObject(response)
            val otp = json?.optString("otp")
            val devices = json?.optInt("devices", -1) ?: -1
            if (otp.isNullOrEmpty() || devices < 0) {
                throw ApiException("Test code returned an incomplete response")
            }
            TestCode(otp = otp, devices = devices)
        }
    }

    /**
     * Checks server health. Never throws.
     * GET /health
     */
    suspend fun checkHealth(): ServerHealth = withContext(ioDispatcher) {
        val healthClient = httpClient.newBuilder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()

        val url = "${recordStore.serverUrl}/health"
        val request = Request.Builder()
            .url(url)
            .get()
            .build()

        try {
            val call = healthClient.newCall(request)
            coroutineContext[Job]?.invokeOnCompletion { cause ->
                if (cause != null) call.cancel()
            }
            call.execute().use { response ->
                val json = decodeObject(response)
                val status = json?.optString("status")

                if (response.code == 200 && status == "ok") {
                    ServerHealth(ServerHealthState.REACHABLE)
                } else {
                    val reason = when {
                        response.code == 503 && status != null -> "its database is unavailable"
                        response.code == 200 -> "the answer isn't from a pux server"
                        else -> "HTTP ${response.code}"
                    }
                    ServerHealth(ServerHealthState.SERVER_ERROR, reason)
                }
            }
        } catch (_: SocketTimeoutException) {
            ServerHealth(ServerHealthState.UNREACHABLE, "no answer within 10 s")
        } catch (e: IOException) {
            ServerHealth(ServerHealthState.UNREACHABLE, e.message ?: "network error")
        } catch (e: Exception) {
            ServerHealth(ServerHealthState.UNREACHABLE, e.toString())
        }
    }

    private fun execute(request: Request, coroutineContext: kotlin.coroutines.CoroutineContext): Response {
        val call = httpClient.newCall(request)
        coroutineContext[Job]?.invokeOnCompletion { cause ->
            if (cause != null) call.cancel()
        }
        return call.execute()
    }

    private fun checkResponse(response: Response, action: String) {
        if (response.code == 429) {
            throw RateLimitedException()
        }
        if (!response.isSuccessful) {
            val body = try {
                response.peekBody(1024).string()
            } catch (_: Exception) {
                ""
            }
            val bodyText = if (body.isEmpty()) "(empty body)" else body
            throw ApiException("$action failed (${response.code}): $bodyText")
        }
    }

    private fun errorCode(response: Response): String? {
        return decodeObject(response)?.optString("error")?.takeIf { it.isNotEmpty() }
    }

    private fun decodeObject(response: Response): JSONObject? {
        return try {
            val body = response.peekBody(65536).string()
            JSONObject(body)
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        lateinit var instance: ApiClient
    }
}
