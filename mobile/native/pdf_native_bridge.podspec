Pod::Spec.new do |s|
  s.name = 'pdf_native_bridge'
  s.version = '0.2.0'
  s.summary = 'QPDF and PDFium bridge for 100% PDF Suite'
  s.homepage = 'https://github.com/qpdf/qpdf'
  s.license = { :type => 'MIT' }
  s.author = '100% PDF Suite'
  s.source = { :path => '.' }
  s.source_files = 'pdf_native_bridge.{h,cpp}'
  s.vendored_frameworks = 'prebuilt/ios/PDFium.xcframework', 'prebuilt/ios/QPDF.xcframework'
  s.platform = :ios, '15.5'
  s.frameworks = 'CoreGraphics'
  s.libraries = 'c++', 'z'
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'OTHER_LDFLAGS' => '-Wl,-u,_pdf_open -Wl,-u,_pdf_close -Wl,-u,_pdf_page_count -Wl,-u,_pdf_render -Wl,-u,_pdf_text -Wl,-u,_pdf_free -Wl,-u,_pdf_qpdf_job -Wl,-u,_pdf_redact -Wl,-u,_pdf_blank -Wl,-u,_pdf_scrub -Wl,-u,_pdf_crop -Wl,-u,_pdf_markup -Wl,-u,_pdf_ink -Wl,-u,_pdf_write_text -Wl,-u,_pdf_form_fields -Wl,-u,_pdf_fill_field -Wl,-u,_pdf_render_tile -Wl,-u,_pdf_metadata'
  }
end
