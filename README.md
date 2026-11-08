# CutLab ✂️ — editor de vídeo estilo CapCut

Editor de vídeo que funciona en el navegador y se instala como app (PWA) en Android, iPhone y PC.
Todo se procesa **en tu dispositivo**: tus vídeos nunca se suben a internet.

## Funciones

- **Línea de tiempo** con cursor central (como CapCut), zoom con pellizco y tres pistas: texto, vídeo y audio
- **Importar** vídeos, fotos y música desde la galería
- **Recortar** con las asas blancas, **dividir**, **duplicar**, **reordenar** (mantén pulsado y arrastra) y **eliminar**
- **Velocidad** 0.1x – 4x, **volumen** hasta 200 %
- **10 filtros** + ajustes de brillo, contraste, saturación y desenfoque
- **8 transiciones**: fundido, a negro, destello, zoom, deslizar, subir, desenfoque
- **Movimiento Ken Burns** (acercar, alejar, paneo) — ideal para fotos
- **Encuadre**: ajustar/rellenar, zoom, girar 90°, espejo
- **Textos** con 8 plantillas, 6 fuentes, contorno, fondo, sombra, brillo neón y animaciones (pop, zoom, máquina de escribir…). Se arrastran y se pellizcan directamente en la vista previa
- **Música** con fundido de entrada y salida
- **Formatos** 9:16, 16:9, 1:1, 4:5, 3:4 y fondo desenfocado automático
- **Deshacer / rehacer** y **guardado automático** del proyecto
- **Exportar** en 480p, 720p o 1080p a 24/30/60 fps (MP4 o WebM según el navegador) y compartir directamente
- Funciona **sin conexión** después de la primera visita

## Instalar desde GitHub (GitHub Pages)

1. Entra en GitHub con tu cuenta y crea un repositorio nuevo llamado **`cutlab`** (público).
2. Pulsa **Add file → Upload files** y sube **todos** los archivos de esta carpeta (están todos en la raíz, sin subcarpetas). Pulsa **Commit changes**.
3. Ve a **Settings → Pages**. En *Build and deployment* elige **Source: Deploy from a branch**, rama **main** y carpeta **/ (root)**. Pulsa **Save**.
4. Espera 1–2 minutos y abre:
   `https://lunaxoxone2025-beep.github.io/cutlab/`
5. Instala la app:
   - **Android (Chrome):** botón **Instalar** arriba en la app, o menú ⋮ → *Instalar aplicación*.
   - **iPhone (Safari):** botón Compartir → *Añadir a pantalla de inicio*.
   - **PC (Chrome / Edge):** icono de instalar en la barra de direcciones.

### Con git (alternativa)

```bash
git init
git add .
git commit -m "CutLab"
git branch -M main
git remote add origin https://github.com/lunaxoxone2025-beep/cutlab.git
git push -u origin main
```

Luego activa Pages como en el paso 3.

## Actualizar la app

Sube los archivos nuevos al repositorio. La app instalada descarga la versión nueva la próxima vez que la abras con conexión.

## Notas

- La exportación se graba en **tiempo real** (un vídeo de 30 s tarda unos 30 s). Mantén la pantalla encendida y la app abierta.
- En Safari (iPhone) los filtros de color pueden no aplicarse; el resto funciona.
- Los proyectos se guardan en el almacenamiento del navegador. Si borras los datos del sitio, se borra el proyecto.
- Atajos en PC: `Espacio` reproducir · `S` dividir · `Supr` borrar · `Ctrl+Z` / `Ctrl+Y` deshacer/rehacer · `←` `→` fotograma a fotograma.
