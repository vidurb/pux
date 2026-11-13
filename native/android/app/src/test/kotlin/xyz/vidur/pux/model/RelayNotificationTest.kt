package xyz.vidur.pux.model

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class RelayNotificationTest {

    @Test
    fun rendersAnOtp() {
        val json = JSONObject()
        json.put("type", "otp")
        json.put("otp", "482913")
        json.put("sender", "HDFC Bank")
        val notification = RelayNotification.fromPayload(json)

        assertEquals("OTP from HDFC Bank", notification.title)
        assertEquals("482913", notification.body)
        assertEquals("482913", notification.code)
    }

    @Test
    fun treatsPayloadsWithoutTypeAsOtps() {
        val json = JSONObject()
        json.put("otp", "123456")
        json.put("sender", "ICICI")
        val notification = RelayNotification.fromPayload(json)
        assertEquals("OTP from ICICI", notification.title)
        assertEquals("123456", notification.code)
    }

    @Test
    fun marksUnverifiedSenders() {
        val json = JSONObject()
        json.put("type", "otp")
        json.put("otp", "482913")
        json.put("sender", "hdfcbank.example")
        json.put("verified", false)
        val notification = RelayNotification.fromPayload(json)
        assertEquals("OTP from hdfcbank.example (unverified)", notification.title)
    }

    @Test
    fun rendersForwardingConfirmationWithNullCodeAndUrl() {
        val json = JSONObject()
        json.put("type", "forward_confirm")
        json.put("code", JSONObject.NULL)
        json.put("url", JSONObject.NULL)
        json.put("sender", "Gmail")
        json.put("forwarding_from", "someone@gmail.com")
        val notification = RelayNotification.fromPayload(json)
        assertEquals("Email forwarding confirmation", notification.title)
        assertTrue(notification.body.contains("Forwarding from someone@gmail.com"))
        assertNull(notification.code)
        assertTrue(notification.body.contains("null").not())
    }

    @Test
    fun jsonNullFieldsAreNotRenderedAsLiteralNullStrings() {
        val json = JSONObject()
        json.put("type", "forward_confirm")
        json.put("code", JSONObject.NULL)
        json.put("url", "https://example.test/confirm")
        json.put("sender", "noreply")
        val notification = RelayNotification.fromPayload(json)
        assertNull(notification.code)
        assertTrue(notification.body.contains("Code: null").not())
    }

    @Test
    fun unknownTypeCarriesUnverifiedMarker() {
        val json = JSONObject()
        json.put("type", "future_type")
        json.put("otp", "111111")
        json.put("sender", "Bank")
        val notification = RelayNotification.fromPayload(json)
        assertEquals("OTP from Bank (unverified)", notification.title)
    }

    @Test
    fun rejectsUntrustedConfirmationUrl() {
        assertNull(RelayNotification.confirmationUri("http://mail.google.com/confirm"))
        assertNull(RelayNotification.confirmationUri("https://phishing.com/confirm"))
        assertNotNull(RelayNotification.confirmationUri("https://mail.google.com/mail/f/confirm/123"))
    }
}
