package com.mansfera.lynxreminders

import android.content.Intent
import android.os.Bundle
import android.text.format.DateFormat
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import com.mansfera.lynxreminders.ui.AppRoot
import com.mansfera.lynxreminders.ui.AppVM
import com.mansfera.lynxreminders.ui.Fmt
import com.mansfera.lynxreminders.ui.LynxTheme
import com.mansfera.lynxreminders.ui.Route

class MainActivity : ComponentActivity() {
    private val vm: AppVM by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
        )
        Fmt.is24 = DateFormat.is24HourFormat(this)
        handle(intent)
        setContent {
            val dark = isSystemInDarkTheme()
            LaunchedEffect(dark) {
                // Status/navigation bar icons follow the app theme (light icons on the dark theme)
                enableEdgeToEdge(
                    statusBarStyle = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT) else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
                    navigationBarStyle = if (dark) SystemBarStyle.dark(android.graphics.Color.TRANSPARENT) else SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
                )
            }
            LynxTheme(dark) { AppRoot(vm) }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** lynxreminders://reminder/<id> (notification tap) opens the reminder. */
    private fun handle(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme == "lynxreminders" && uri.host == "reminder") {
            val id = uri.lastPathSegment ?: return
            if (vm.g.store.value.reminders.containsKey(id)) {
                if (vm.top is Route.Welcome) vm.reset(Route.Home)
                vm.push(Route.Editor(id))
            }
        }
    }
}
