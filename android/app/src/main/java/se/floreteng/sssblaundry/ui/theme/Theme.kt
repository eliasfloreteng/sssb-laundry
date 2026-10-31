package se.floreteng.sssblaundry.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/**
 * Material You first: the wallpaper's colours where the phone has them (Android
 * 12+). Elsewhere, a scheme built around SSSB's brand blue `#064A88`, with the
 * lighter `#3E8BC8` for dark mode — `#064A88` on black has no usable contrast.
 */
private val BrandLight = lightColorScheme(
    primary = Color(0xFF064A88),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD4E3FF),
    onPrimaryContainer = Color(0xFF001C3A),
    secondary = Color(0xFF545F71),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFD8E3F8),
    onSecondaryContainer = Color(0xFF111C2B),
    tertiary = Color(0xFF6D5677),
    tertiaryContainer = Color(0xFFF6D9FF),
    onTertiaryContainer = Color(0xFF261431),
    background = Color(0xFFF9F9FF),
    surface = Color(0xFFF9F9FF),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFF3F3FA),
    surfaceContainer = Color(0xFFEDEDF4),
    surfaceContainerHigh = Color(0xFFE7E8EE),
    surfaceContainerHighest = Color(0xFFE2E2E9),
)

private val BrandDark = darkColorScheme(
    primary = Color(0xFFA5C8FF),
    onPrimary = Color(0xFF00315F),
    primaryContainer = Color(0xFF3E8BC8),
    onPrimaryContainer = Color.White,
    secondary = Color(0xFFBCC7DB),
    secondaryContainer = Color(0xFF3C4758),
    onSecondaryContainer = Color(0xFFD8E3F8),
    tertiary = Color(0xFFD9BDE3),
    tertiaryContainer = Color(0xFF543F5E),
    onTertiaryContainer = Color(0xFFF6D9FF),
    background = Color(0xFF111318),
    surface = Color(0xFF111318),
    surfaceContainerLowest = Color(0xFF0C0E13),
    surfaceContainerLow = Color(0xFF191C20),
    surfaceContainer = Color(0xFF1D2024),
    surfaceContainerHigh = Color(0xFF282A2F),
    surfaceContainerHighest = Color(0xFF33353A),
)

@Composable
fun SssbLaundryTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val colorScheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        dark -> BrandDark
        else -> BrandLight
    }
    MaterialExpressiveTheme(
        colorScheme = colorScheme,
        motionScheme = MotionScheme.expressive(),
        content = content,
    )
}
