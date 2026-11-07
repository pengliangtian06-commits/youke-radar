"""Synthetic demo fixtures; not screenshots of a real student conversation."""
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont

root = Path(__file__).resolve().parents[1]
out = root / 'demo'
out.mkdir(exist_ok=True)
today = datetime.now(timezone(timedelta(hours=8)))
due = (today + timedelta(days=4)).strftime('%Y-%m-%d')
changed = (today + timedelta(days=2)).strftime('%Y-%m-%d')
lines = ['计算机网络 · 实验一', f'截止时间：{due} 20:00', '提交方式：教学平台', '要求：PDF实验报告，', '包含抓包截图与协议分析。']
font = 'C:/Windows/Fonts/msyh.ttc'
im = Image.new('RGB', (1080, 1200), '#F5F6FA')
d = ImageDraw.Draw(im)
d.rounded_rectangle((65, 65, 1015, 210), radius=28, fill='#3549B8')
d.text((110, 100), '课程通知 / 演示材料', font=ImageFont.truetype(font, 48), fill='white')
d.rounded_rectangle((65, 270, 1015, 970), radius=28, fill='white')
for n, line in enumerate(lines):
    d.text((110, 325 + n * 110), line, font=ImageFont.truetype(font, 38), fill='#202B47')
d.text((80, 1060), '人工构造示例，用于现场测试，不含个人信息。', font=ImageFont.truetype(font, 28), fill='#66718A')
im.save(out / 'notice.png')
(out / 'notice.txt').write_text('\n'.join(lines), encoding='utf-8')
(out / 'change.txt').write_text(f'【演示材料】计算机网络实验一截止时间提前至{changed} 20:00，其他要求不变。', encoding='utf-8')
(out / 'missing-date.txt').write_text('【演示材料】数据结构：链表作业。请提交源代码，截止时间另行通知。', encoding='utf-8')
pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
pdf = canvas.Canvas(str(out / 'course-outline.pdf'))
pdf.setTitle('邮课雷达演示课程大纲')
pdf.setFillColorRGB(.20, .28, .72)
pdf.setFont('STSong-Light', 25)
pdf.drawString(55, 765, '计算机网络 / 课程大纲')
pdf.setFillColorRGB(.15, .18, .25)
pdf.setFont('STSong-Light', 14)
for index, line in enumerate(['演示材料 - 人工构造，不代表学校实际教学安排。', *lines, '请在提交前检查文件格式与图表清晰度。']):
    pdf.drawString(55, 695 - index * 42, line)
pdf.setFont('STSong-Light', 10)
pdf.drawString(55, 55, '邮课雷达现场评测资料 / 第 1 页')
pdf.save()
try:
    import fitz
    doc = fitz.open(out / 'course-outline.pdf')
    doc[0].get_pixmap(matrix=fitz.Matrix(1, 1)).save(out / 'course-outline-preview.png')
except ImportError:
    print('Install pymupdf to render PDF preview.')
print('Created synthetic demo files in demo/')
