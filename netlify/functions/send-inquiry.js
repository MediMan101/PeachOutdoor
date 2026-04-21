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
      newsletterOptIn
    } = data;

    const emailBody =
`First Name: ${firstName || ''}
Last Name: ${lastName || ''}
Work Phone: ${phone || ''}
Email Address: ${email || ''}
Interested Make: ${interestedMake || ''}
Interested Model: ${interestedModel || ''}
Interested Location: ${location || 'Clanton'}
telephone: ${phone || ''}
Address: ${address || ''}
City: ${city || ''}
State: ${state || ''}
Zip: ${zip || ''}
Condition: ${condition || 'New'}
Location: ${location || 'Clanton'}
SourcePage: inquiry
formpage: inquiry
NewsletterOptIn: ${newsletterOptIn ? 'Y' : 'N'}
[Inquiry][]
${itemUrl || ''}`;

    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: 'Peach Outdoor Inquiries <onboarding@resend.dev>',
        to: [
          'sherylsmith147@gmail.com',
          'john.medicomp@gmail.com',
          'markstowingandauto@gmail.com',
          'peachout.inventory@gmail.com'
        ],
        reply_to: email || undefined,
        subject: 'Peach Outdoor Get A Quote Form',
        text: emailBody
      })
    });

    const result = await response.json();

    if (!response.ok) {
      console.error('Resend error:', JSON.stringify(result));
      // Return the actual Resend error so we can diagnose
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
