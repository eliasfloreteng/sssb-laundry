package se.floreteng.sssblaundry.ui.invite

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * A link as a QR code, for handing it to someone standing next to you.
 *
 * Always dark modules on white, in light and dark theme alike: camera apps read
 * inverted codes unreliably, and the white square doubles as the quiet zone.
 */
@Composable
fun QrCode(text: String, contentDescription: String, modifier: Modifier = Modifier) {
    // Width and height 0 ask ZXing for its natural size: one cell per module.
    val modules = remember(text) {
        QRCodeWriter().encode(
            text, BarcodeFormat.QR_CODE, 0, 0,
            mapOf(
                EncodeHintType.MARGIN to 0,
                EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            ),
        )
    }

    Surface(
        shape = RoundedCornerShape(16.dp),
        color = Color.White,
        modifier = modifier.aspectRatio(1f).semantics { this.contentDescription = contentDescription },
    ) {
        Canvas(Modifier.padding(12.dp).fillMaxSize()) {
            val cell = size.width / modules.width
            // One path, so neighbouring modules fill as one shape with no
            // antialiased seams between them.
            val path = Path()
            for (y in 0 until modules.height) {
                for (x in 0 until modules.width) {
                    if (modules[x, y]) path.addRect(Rect(x * cell, y * cell, (x + 1) * cell, (y + 1) * cell))
                }
            }
            drawPath(path, Color.Black)
        }
    }
}
