exports.handler = async (event, context) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: JSON.stringify({ error: 'Method not allowed' }) };
  }

  try {
    const data = JSON.parse(event.body);

    const {
      firstName, lastName, phone, email,
      address, city, state, zip,
      interestedMake, interestedModel,
      condition, location, itemId, itemUrl,
      serialNumber, itemLocation,
      newsletterOptIn, message
    } = data;

    const fullName = `${firstName || ''} ${lastName || ''}`.trim();
    const fullAddress = [address, city, state, zip].filter(Boolean).join(', ');
    const now = new Date().toLocaleString('en-US', { timeZone: 'America/Chicago', dateStyle: 'full', timeStyle: 'short' });

    const htmlBody = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: Arial, sans-serif; font-size: 15px; color: #222; background: #f4f4f4; margin: 0; padding: 20px; }
    .wrapper { max-width: 600px; margin: 0 auto; background: #ffffff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
    .header { background: #2a7d2e; padding: 24px 32px; }
    .header h1 { margin: 0; color: #ffffff; font-size: 22px; letter-spacing: 0.5px; }
    .header p { margin: 4px 0 0; color: #c8e6c9; font-size: 13px; }
    .body { padding: 28px 32px; }
    .section { margin-bottom: 24px; }
    .section-title { font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 1px; color: #888; border-bottom: 1px solid #e0e0e0; padding-bottom: 6px; margin-bottom: 14px; }
    .field { display: flex; margin-bottom: 10px; }
    .label { font-size: 13px; color: #666; width: 140px; flex-shrink: 0; padding-top: 1px; }
    .value { font-size: 15px; color: #111; font-weight: 500; }
    .highlight { background: #f1f8f1; border-left: 4px solid #2a7d2e; border-radius: 4px; padding: 14px 18px; margin-bottom: 24px; }
    .highlight .make { font-size: 18px; font-weight: 700; color: #2a7d2e; }
    .highlight .model { font-size: 15px; color: #444; margin-top: 2px; }
    .highlight .condition { display: inline-block; margin-top: 8px; background: #2a7d2e; color: #fff; font-size: 11px; font-weight: 700; padding: 3px 10px; border-radius: 20px; text-transform: uppercase; letter-spacing: 0.5px; }
    .item-link { display: inline-block; margin-top: 10px; color: #2a7d2e; font-size: 13px; word-break: break-all; }
    .footer { background: #f9f9f9; border-top: 1px solid #e0e0e0; padding: 16px 32px; font-size: 12px; color: #999; }
    .newsletter { display: inline-block; background: ${newsletterOptIn ? '#e8f5e9' : '#fafafa'}; color: ${newsletterOptIn ? '#2a7d2e' : '#999'}; border: 1px solid ${newsletterOptIn ? '#a5d6a7' : '#ddd'}; font-size: 12px; padding: 3px 10px; border-radius: 20px; }
  </style>
</head>
<body>
  <div class="wrapper">
    <div class="header">
      <h1>&#128203; New Quote Inquiry</h1>
      <p>Submitted ${now} &mdash; Peach Outdoor, Clanton AL</p>
    </div>
    <div class="body">

      <div class="section">
        <div class="section-title">Interested In</div>
        <div class="highlight">
          <div class="make">${interestedMake || ''}</div>
          <div class="model">${interestedModel || ''}</div>
          ${serialNumber ? `<div class="field" style="margin-top:8px;"><span class="label">Serial #</span><span class="value">${serialNumber}</span></div>` : ''}
          ${itemLocation ? `<div class="field"><span class="label">Location</span><span class="value">${itemLocation}</span></div>` : ''}
          <div class="condition">${condition || 'New'}</div>
          ${itemUrl ? `<br><a class="item-link" href="${itemUrl}">View Item on Website &rarr;</a>` : ''}
        </div>
      </div>

      <div class="section">
        <div class="section-title">Customer Information</div>
        <div class="field"><span class="label">Name</span><span class="value">${fullName}</span></div>
        <div class="field"><span class="label">Phone</span><span class="value"><a href="tel:${phone}" style="color:#2a7d2e;">${phone || ''}</a></span></div>
        <div class="field"><span class="label">Email</span><span class="value"><a href="mailto:${email}" style="color:#2a7d2e;">${email || ''}</a></span></div>
        ${fullAddress ? `<div class="field"><span class="label">Address</span><span class="value">${fullAddress}</span></div>` : ''}
      </div>

      <div class="section">
        <div class="section-title">Preferences</div>
        <div class="field"><span class="label">Location</span><span class="value">${location || 'Clanton'}</span></div>
        <div class="field"><span class="label">Newsletter</span><span class="value"><span class="newsletter">${newsletterOptIn ? '✓ Opted In' : 'No'}</span></span></div>
      </div>

      ${message ? `
      <div class="section">
        <div class="section-title">Customer Message</div>
        <div style="background:#f9f9f9;border:1px solid #e0e0e0;border-radius:6px;padding:14px 16px;font-size:15px;color:#333;line-height:1.6;white-space:pre-wrap;">${message}</div>
      </div>` : ''}

    </div>
    <div class="footer">
      This inquiry was submitted via the Get A Quote form on peachoutdoor.com &mdash; Reply directly to this email to respond to the customer.
    </div>
  </div>
</body>
</html>`;

    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: 'Peach Outdoor Inquiries <noreply@peachoutdoor.com>',
        to: [
          'sherylsmith147@gmail.com',
          'peachout.john@gmail.com',
          'markstowingandauto@gmail.com',
          'peachout.inventory@gmail.com'
        ],
        reply_to: email || undefined,
        subject: `Quote Inquiry: ${interestedMake || ''} ${interestedModel || ''} — ${fullName}`,
        html: htmlBody
      })
    });

    const result = await response.json();

    if (!response.ok) {
      console.error('Resend error:', JSON.stringify(result));
      return {
        statusCode: 500,
        body: JSON.stringify({ error: 'Resend rejected', resend_status: response.status, resend_details: result })
      };
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ success: true })
    };

  } catch (error) {
    console.error('send-inquiry error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: 'Exception thrown', details: error.message })
    };
  }
};
