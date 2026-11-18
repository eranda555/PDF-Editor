#pragma once
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32) && defined(PDF_BRIDGE_EXPORTS)
#define PDF_API __declspec(dllexport)
#elif defined(_WIN32)
#define PDF_API __declspec(dllimport)
#else
#define PDF_API __attribute__((visibility("default"))) __attribute__((used))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PdfRect {
    int32_t page;
    double x0;
    double y0;
    double x1;
    double y1;
} PdfRect;
PDF_API void* pdf_open(const char* path, const char* password);
PDF_API void pdf_close(void* document);
PDF_API int32_t pdf_page_count(void* document);
PDF_API int32_t pdf_page_size(void* document, int32_t index, double* width, double* height);
/* Returns RGBA pixels allocated by this library. Caller must pdf_free(). */
PDF_API uint8_t* pdf_render(void* document, int32_t index, int32_t max_edge,
    int32_t* width, int32_t* height, size_t* size);
/* UTF-8 text allocated by this library. Caller must pdf_free(). */
PDF_API char* pdf_text(void* document, int32_t index);
PDF_API int32_t pdf_qpdf_job(const char* job_json);
PDF_API int32_t pdf_blank(const char* output, double width, double height);
/* Top-left normalized boxes. Entire output is rebuilt from raster pages. */
PDF_API int32_t pdf_redact(void* document, const char* output, const PdfRect* boxes, int32_t count, int32_t dpi);
PDF_API void pdf_free(void* memory);
/* Fixed error codes only: never returns paths, passwords, or document content. */
PDF_API int32_t pdf_last_error(void);
PDF_API int32_t pdf_scrub(const char* input, const char* output);
PDF_API int32_t pdf_crop(void* document, const char* output, const PdfRect* boxes, int32_t count);
PDF_API int32_t pdf_markup(void* document, const char* output, const PdfRect* boxes, int32_t count, int32_t kind);
PDF_API int32_t pdf_ink(void* document, const char* output, int32_t page, const double* xy, int32_t points);
PDF_API int32_t pdf_write_text(void* document, const char* output, int32_t page, double x, double y,
    const uint16_t* text, double size, int32_t signature);
/* JSON array of {name,type,value,options}; memory belongs to caller. */
PDF_API char* pdf_form_fields(const char* input);
PDF_API char* pdf_metadata(const char* input);
PDF_API int32_t pdf_fill_field(const char* input, const char* output, const char* name, const char* value);
PDF_API uint8_t* pdf_render_tile(void* document, int32_t page, int32_t full_width, int32_t full_height,
    int32_t x, int32_t y, int32_t width, int32_t height);
#ifdef __cplusplus
}
#endif
