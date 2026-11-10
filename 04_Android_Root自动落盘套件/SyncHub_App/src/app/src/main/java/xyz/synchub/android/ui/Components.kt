package xyz.synchub.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun Dot(color: Color) = Box(Modifier.size(8.dp).background(color, CircleShape))

@Composable
fun StatusRow(title: String, value: String, color: Color, sub: String? = null, onClick: (() -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth()
            .let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Dot(color)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Mac.Text, fontSize = 15.sp)
            if (sub != null) Text(sub, color = Mac.Text2, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Text(value, color = if (color == Mac.Red || color == Mac.Orange) color else Mac.Text2, fontSize = 14.sp)
    }
}

@Composable
fun SwitchRow(title: String, sub: String? = null, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = Mac.Text, fontSize = 15.sp)
            if (sub != null) Text(sub, color = Mac.Text2, fontSize = 12.sp)
        }
        Switch(checked = checked, onCheckedChange = onChange, colors = SwitchDefaults.colors(
            checkedTrackColor = Mac.Green, checkedThumbColor = Color.White, checkedBorderColor = Mac.Green,
            uncheckedTrackColor = Mac.Fill, uncheckedThumbColor = Color.White, uncheckedBorderColor = Mac.Hairline,
        ))
    }
}

@Composable
fun MacField(label: String, value: String, onChange: (String) -> Unit, password: Boolean = false,
             keyboard: KeyboardType = KeyboardType.Text, modifier: Modifier = Modifier) {
    OutlinedTextField(
        value = value, onValueChange = onChange, label = { Text(label, fontSize = 13.sp) }, singleLine = true,
        visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = if (password) KeyboardType.Password else keyboard),
        shape = RoundedCornerShape(8.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = Mac.Accent, unfocusedBorderColor = Mac.Hairline,
            focusedContainerColor = Color.White, unfocusedContainerColor = Color.White,
            focusedLabelColor = Mac.Accent, unfocusedLabelColor = Mac.Text2,
        ),
        modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
    )
}

@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick = onClick, enabled = enabled, shape = RoundedCornerShape(8.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Mac.Accent, disabledContainerColor = Mac.Hairline),
        elevation = null,
        modifier = modifier.fillMaxWidth().height(44.dp)) {
        Text(text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun LinkButton(text: String, color: Color = Mac.Accent, onClick: () -> Unit) {
    TextButton(onClick = onClick) { Text(text, color = color, fontSize = 15.sp) }
}

@Composable
fun ActionRow(title: String, sub: String? = null, color: Color = Mac.Accent, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = color, fontSize = 15.sp)
            if (sub != null) Text(sub, color = Mac.Text2, fontSize = 12.sp)
        }
        Text("›", color = Mac.Text3, fontSize = 20.sp)
    }
}

@Composable
fun TopBar(title: String, left: (@Composable () -> Unit)? = null, right: (@Composable () -> Unit)? = null) {
    Column {
        Row(Modifier.fillMaxWidth().background(Mac.Bg).padding(horizontal = 8.dp, vertical = 6.dp).height(44.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Box(Modifier.weight(1f)) { left?.invoke() }
            Text(title, color = Mac.Text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) { right?.invoke() }
        }
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(Mac.Hairline))
    }
}
