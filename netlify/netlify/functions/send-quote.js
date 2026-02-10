const nodemailer = require('nodemailer');

exports.handler = async (event, context) => {
  // Only allow POST requests
  if (event.httpMethod !== 'POST') {
    return {
      statusCode: 405,
      body: JSON.stringify({ error: 'Method not allowed' })
    };
  }

  try {
    const data = JSON.parse(event.body);
    
    // Extract data from request
    const {
      customerName,
      customerEmail,
      customerPhone,
      brand,
      model,
      basePrice,
      options,
      total
    } = data;

    // Create email content
    const emailSubject = `Quote Request - ${brand} ${model}`;
    const emailBody = `
NEW QUOTE REQUEST

CUSTOMER INFORMATION:
Name: ${customerName}
Email: ${customerEmail}
Phone: ${customerPhone}

CONFIGURATION:
Brand: ${brand}
Model: ${model}
Base Price: ${basePrice}

OPTIONS:
${options}

${total}

---
This quote request was submitted from the Peach Outdoor website configurator.
    `;

    // Configure email using environment variables
    // You'll set these in Netlify dashboard
    const transporter = nodemailer.createTransport({
      service: 'gmail',
      auth: {
        user: process.env.EMAIL_USER,
        pass: process.env.EMAIL_PASS
      }
    });

    // Send email
    await transporter.sendMail({
      from: process.env.EMAIL_USER,
      to: 'peachout.john@gmail.com',
      replyTo: customerEmail,
      subject: emailSubject,
      text: emailBody
    });

    return {
      statusCode: 200,
      body: JSON.stringify({ 
        success: true, 
        message: 'Quote request sent successfully!' 
      })
    };

  } catch (error) {
    console.error('Error sending email:', error);
    return {
      statusCode: 500,
      body: JSON.stringify({ 
        error: 'Failed to send quote request',
        details: error.message 
      })
    };
  }
};
