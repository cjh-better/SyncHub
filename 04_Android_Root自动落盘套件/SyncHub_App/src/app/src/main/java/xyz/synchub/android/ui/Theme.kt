package xyz.synchub.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 与 Web 端改版一致的 macOS 浅色扁平配色：白 / 浅灰、发丝分隔线、唯一的系统蓝强调色。 */
object Mac {
    val Bg = Color(0xFFF5F5F7)
    val Card = Color.White
    val Hairline = Color(0xFFE5E5EA)
    val Text = Color(0xFF1D1D1F)
    val Text2 = Color(0xFF6E6E73)
    val Text3 = Color(0xFFAEAEB2)
    val Accent = Color(0xFF007AFF)
    val AccentSoft = Color(0xFFE8F1FE)
    val Green = Color(0xFF34C759)
    val Orange = Color(0xFFFF9500)
    val Red = Color(0xFFFF3B30)
    val Fill = Color(0xFFF2F2F7)
}

@Composable
fun SyncHubTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = Mac.Accent, onPrimary = Color.White,
            background = Mac.Bg, surface = Mac.Card, onSurface = Mac.Text, onBackground = Mac.Text,
            surfaceVariant = Mac.Fill, outline = Mac.Hairline, outlineVariant = Mac.Hairline,
            secondaryContainer = Mac.AccentSoft, onSecondaryContainer = Mac.Accent,
            error = Mac.Red,
        ),
        content = content,
    )
}

private val CardShape = RoundedCornerShape(12.dp)

@Composable
fun MacCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier
            .fillMaxWidth()
            .background(Mac.Card, CardShape)
            .border(0.5.dp, Mac.Hairline, CardShape),
        content = content,
    )
}

@Composable
fun SectionTitle(text: String) {
    Text(text, color = Mac.Text2, fontSize = 13.sp, fontWeight = FontWeight.Medium,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 6.dp))
}

@Composable
fun Hairline(startPad: Int = 16) {
    Box(Modifier.padding(start = startPad.dp).fillMaxWidth().height(0.5.dp).background(Mac.Hairline))
}
