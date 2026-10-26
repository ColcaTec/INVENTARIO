# Configurar OCR con Google Document AI

La función `receipt-ocr` usa el procesador **Invoice Parser** para sugerir proveedor y número desde la foto. La foto se envía a Google Document AI para procesarla. El navegador conserva la imagen original para el comprobante; la llamada OCR usa una copia JPEG reducida.

## Secretos requeridos en Supabase

En el proyecto de Supabase, abre **Edge Functions → Secrets** y agrega:

- `DOC_AI_PROJECT_ID`: ID del proyecto de Google Cloud.
- `DOC_AI_LOCATION`: región donde está el processor (por ejemplo `us` o `eu`).
- `DOC_AI_PROCESSOR_ID`: ID del procesador Invoice Parser.
- `GOOGLE_SERVICE_ACCOUNT_JSON`: contenido completo del JSON de la cuenta de servicio.

No guardes el JSON ni su clave privada en GitHub, en `config.js`, ni en el navegador. La cuenta de servicio debe tener permiso para ejecutar el procesador Document AI en el proyecto de Google Cloud y Document AI debe estar habilitado.

## Despliegue

Despliega `index.ts` como función Supabase llamada `receipt-ocr` con verificación JWT habilitada (`verify_jwt: true`). Luego vuelve a cargar la app.

Si Document AI aún no está configurado, la app intenta OCR local como alternativa. Los campos sugeridos siempre se deben revisar manualmente.
