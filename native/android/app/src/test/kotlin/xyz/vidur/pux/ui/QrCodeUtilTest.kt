package xyz.vidur.pux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [34])
class QrCodeUtilTest {

    @Test
    fun testGenerateQrBitmap() {
        val testContent = "{\"v\":1,\"record_id\":\"test-123\"}"
        val bitmap = QrCodeUtil.generateQrBitmap(testContent, 256)
        assertNotNull(bitmap)
        assertEquals(256, bitmap.width)
        assertEquals(256, bitmap.height)
    }
}
