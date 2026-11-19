# Lotta

Reproductor de música para iOS que se conecta a tu servidor Jellyfin. Está hecho en SwiftUI y se compila desde Linux con [xtool](https://github.com/xtool-org/xtool), sin Mac.

## Qué incluye (v0.1)

- **Descargas sin conexión** con un URLSession en segundo plano, que sigue descargando aunque bloquees el teléfono.
  - Descargas por álbum o por canción.
  - También se guardan la portada y la letra.
  - Sin red, la app muestra solo lo descargado.
- **Biblioteca**: álbumes y artistas, con caché en disco para navegar sin conexión, más búsqueda.
- **Reproductor**:
  - Audio en segundo plano y controles en la pantalla de bloqueo y el Centro de control.
  - AirPlay, cola y repetición.
- **Letras sincronizadas** (Jellyfin 10.9 o superior, archivos `.lrc`):
  - Mantén presionada una línea o toca ⬆︎ para seleccionar hasta 6 líneas.
  - Con eso se crea una tarjeta 9:16 (1080×1920) en tres estilos: Color, Portada o Claro.
  - La tarjeta se puede **compartir** o **guardar en Fotos**.
- **Playlists** de Jellyfin:
  - Verlas, reproducirlas y descargarlas sin conexión.
  - Crear playlists nuevas.
  - Añadir canciones o álbumes enteros.
  - Quitar canciones deslizando la fila.
- **Estilo "Foto"** para la tarjeta de letras: una foto de tu galería de fondo, nítida, y la tarjeta como vidrio esmerilado.
- **Calidad**: Original (FLAC/ALAC/AAC/MP3 sin convertir), MP3 320 o MP3 192. Se elige por separado para streaming y para descargas.

## Requisitos (Linux)

- Swift 6.4, instalado con swiftly en `~/.local/share/swiftly`.
- xtool en `~/.local/bin/xtool`.
- `usbmuxd` (ya instalado).
- **Xcode 27.1 .xip**, que tienes que bajar desde https://developer.apple.com/download/all/?q=Xcode

## Primera vez

```bash
xtool setup        # inicia sesión con tu Apple ID y pide la ruta del Xcode.xip
```

## Compilar e instalar en el iPhone

Conecta el iPhone por USB, desbloquéalo y confía en la computadora. Después:

```bash
cd ~/Desktop/lottamusic2
xtool dev
```

En el iPhone, la primera vez: **Ajustes → General → VPN y administración de dispositivos** → confía en tu Apple ID. En iOS 16 o superior también tienes que activar el **Modo de desarrollador** en Ajustes → Privacidad y seguridad.

> Con un Apple ID gratuito la app caduca a los 7 días. Para renovarla vuelve a correr `xtool dev`. Tus descargas se conservan.

## Estructura

```
Sources/Lotta/
  LottaApp.swift          App, AppModel, AppDelegate (eventos de descargas en 2º plano)
  Core/
    JellyfinClient.swift  API REST de Jellyfin
    DownloadManager.swift Descargas offline
    LibraryStore.swift    Biblioteca + caché, monitor de red
    Player.swift          AVPlayer, pantalla de bloqueo, controles remotos
    Caches.swift          Portadas y letras en disco
    Storage.swift         Archivos y Keychain
  Views/                  SwiftUI
Info.plist                Audio en 2º plano, permiso de Fotos, HTTP local
xtool.yml
```
