# frozen_string_literal: true

# In-memory PDF builder, a copy of pikuri-pdf's spec helper: emits the
# smallest valid PDF +pdf-reader+ will accept — one page per text,
# Helvetica, a single +Tj+ string-show op — so assertions exercise
# the real extraction path end-to-end without checking a binary
# fixture into the repo.
module BuildPdf
  # Build a PDF that prints each of +page_texts+ on its own page — a
  # String as one line, an Array of Strings as one line each.
  # Returns the raw bytes ready to wrap in a StringIO or binwrite to
  # disk. Object byte offsets are computed as we append, so the xref
  # table is always correct.
  #
  #   build_pdf('Hello PDF', ['first line', 'second line'])   # two pages
  def build_pdf(*page_texts)
    out = +"%PDF-1.4\n"
    offsets = []
    add_obj = lambda do |body|
      offsets << out.bytesize
      out << "#{offsets.size} 0 obj\n#{body}\nendobj\n"
    end

    page_count = page_texts.length
    font_obj_num = 2 + page_count * 2 + 1

    add_obj.call('<< /Type /Catalog /Pages 2 0 R >>')
    page_refs = (0...page_count).map { |i| "#{3 + i * 2} 0 R" }
    add_obj.call("<< /Type /Pages /Kids [#{page_refs.join(' ')}] /Count #{page_count} >>")

    page_texts.each_with_index do |text, i|
      content_obj_num = 3 + i * 2 + 1
      add_obj.call("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
                   "/Contents #{content_obj_num} 0 R /Resources << /Font << /F1 #{font_obj_num} 0 R >> >> >>")
      shown = text.is_a?(Array) ? "14 TL #{text.map { |line| "(#{line}) Tj T*" }.join(' ')}" : "(#{text}) Tj"
      stream = "BT /F1 12 Tf 100 700 Td #{shown} ET"
      add_obj.call("<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream")
    end

    add_obj.call('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

    xref_pos = out.bytesize
    out << "xref\n0 #{offsets.size + 1}\n"
    out << "0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{offsets.size + 1} /Root 1 0 R >>\n"
    out << "startxref\n#{xref_pos}\n%%EOF\n"
    out
  end
end
