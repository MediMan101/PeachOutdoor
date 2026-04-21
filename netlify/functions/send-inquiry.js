const nodemailer = require('nodemailer');

exports.handler = async (event, context) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: JSON.stringify({ error: 'Method not allowed' }) };
  }

  try {
    const data = JSON.parse(event.body);

    const {
      firstName,
      lastName,
      phone,
      email,
      address,
      city,
      state,
      zip,
      interestedMake,
      interestedModel,
      condition,
      location,
      itemId,
      itemUrl,
      newsletterOptIn
    } = data;

    const subject = `Peach Outdoor Get A Quote Form`;

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
${itemUrl || ''}
`;

    const transporter = nodemailer.createTransport({
      service: 'gmail',
      auth: {
        user: process.env.EMAIL_USER,
        pass: process.env.EMAIL_PASS
      }
    });

    // Distribution list: sherylsmith147, john, markstowingandauto, peachout.inventory
    // (rayfarris0 excluded per request)
    const recipients = [
      'sherylsmith147@gmail.com',
      process.env.EMAIL_USER,
      'markstowingandauto@gmail.com',
      'peachout.inventory@gmail.com'
    ].join(', ');

    await transporter.sendMail({
      from: process.env.EMAIL_USER,
      to: recipients,
      replyTo: email || '',
      subject: subject,
      text: emailBody
    });

    return {
      statusCode: 200,
      body: JSON.stringify({ success: true, message: 'Your inquiry has been sent!' })
    };

  } catch (error) {
    console.error('send-inquiry error:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: 'Failed to send inquiry', details: error.message })
    };
  }
};
