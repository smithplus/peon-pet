# Plan: curado de packs + editor de sonidos

Estado: `[ ]` pendiente · `[~]` en curso · `[x]` hecho

## Contexto

27 de 37 packs instalados tienen el mismo archivo de sonido alcanzable desde dos
o más categorías. Es el mismo defecto que corregimos a mano en `campesino_es`:
hace que dos eventos distintos suenen igual, que es justo lo que la herramienta
tiene que evitar. La parte estructural se puede arreglar mecánicamente; la parte
semántica (qué frase significa "terminé") no, y para eso va el editor.

## Fase A — Curado estructural automático

- [x] A1. Herramienta `Tools/curate.py` que detecta solapamientos entre categorías
- [x] A2. Regla de prioridad: cada archivo queda en su categoría más específica
- [x] A3. Guardia: ninguna categoría puede quedar vacía tras el dedup
- [x] A4. Backup del manifiesto original como `openpeon.json.orig` (reversible)
- [x] A5. Aplicar a los 27 packs afectados, sin tocar los 10 sanos
- [x] A6. Validar: 0 solapamientos, 0 huérfanos, todos los archivos existen
- [x] A7. Verificar con `peon preview` que los packs siguen sonando

## Fase B — Editor de sonidos

- [x] B1. Modelo `SoundEditor.swift`: leer pack → categorías → sonidos con etiqueta
- [x] B2. Escribir cambios al manifiesto preservando el resto del JSON
- [x] B3. Ventana SwiftUI: una sección por evento, un renglón por sonido
- [x] B4. Botón de play por sonido (escuchar antes de decidir)
- [x] B5. Mover un sonido de un evento a otro
- [x] B6. Restaurar el pack a su estado original
- [x] B7. Abrir el editor desde Ajustes

## Fase C — Verificación

- [x] C1. Auditoría con `PEONPET_DEBUG=1` de cada camino nuevo
- [x] C2. Snapshot del editor renderizado
- [x] C3. Medir CPU y RAM (no debe subir de ~0.1% / ~55 MB)
- [x] C4. Actualizar memoria del proyecto
