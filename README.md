# Inventario

Aplicación web instalable para registrar productos, movimientos de stock, lotes con vencimiento y recepciones de compras. Usa Supabase para autenticación y persistencia.

## Configuración

1. En Supabase, ejecuta `01_base_de_datos.sql` para una instalación nueva.
2. Ejecuta `02_recepciones.sql` para habilitar proveedores, boletas, líneas de recepción, conteos aleatorios y el bucket privado de imágenes.
3. En `config.js`, configura la URL del proyecto y su clave **publishable**. Nunca uses una clave `secret` o `service_role` en el navegador.
4. Publica los archivos en un host HTTPS. La cámara del celular requiere HTTPS o localhost.

Si el inventario ya tiene instalada la base de datos de la Fase 1, ejecuta solo `02_recepciones.sql`.

## Recepción de compras

Desde **Más → Recepción de compras**, fotografía la boleta y ejecuta el OCR opcional en español. El OCR muestra texto de referencia y puede sugerir el proveedor; verifica los datos en la boleta. Luego escanea o elige cada producto, registra lo indicado en la boleta, lo que realmente llegó, su vencimiento, ubicación y costo unitario. Las diferencias requieren una nota.

Antes de confirmar, la base de datos elige aleatoriamente entre uno y tres productos que ya tienen stock y los compara por ubicación. El conteo se refiere al stock anterior a la recepción y no lo modifica. Al confirmar, un único procedimiento actualiza los lotes, los costos y el historial; si falla, no aplica una recepción parcial.

Las fotos se guardan en el bucket privado `recepcion-boletas`. El OCR corre en el navegador y usa Tesseract.js con archivos de idioma servidos desde una CDN; la foto se sube al Supabase configurado para la app.
