# Secure AWS S3 + CloudFront Websites Against Clickjacking

## Step 1: Enable CloudFront Function to Add `X-Frame-Options` and `Content-Security-Policy` Headers

### 1. Log in to the AWS Management Console
Go to the **CloudFront** section.

### 2. From the left menu, choose **Functions** and create a new CloudFront Function
- Example Name: `AddSecurityHeaders`
- Function code:

```javascript
function handler(event) {
  if (!event.response) {
    return event;
  }

  var response = event.response;
  var headers = response.headers;

  headers['x-frame-options'] = { value: 'DENY' };
  headers['content-security-policy'] = { value: "frame-ancestors 'none'" };

  return response;
}
```

- Save and deploy the function

<img width="3330" height="722" alt="Image" src="https://github.com/user-attachments/assets/aed6eb5b-68df-4894-b3e3-fdcebddffd48" />

> Note:
> - `X-Frame-Options: DENY` blocks all attempts to embed your website in an iframe.
> - `Content-Security-Policy: frame-ancestors 'none'` is a modern and more robust solution recommended by browsers, with similar effect and broader coverage.

<br>



## Step 2: Associate the Function with Your CloudFront Distribution

1. Locate your target CloudFront Distribution

2. Go to the Behaviors tab

3. Click Edit on the behavior path you want to protect (e.g., Default (*))

4. Under Function associations, set the following:

    - Event type: Viewer Response

    - Function: Choose the CloudFront Function you just created (AddSecurityHeaders)

5. Click Save

<img width="3252" height="734" alt="Image" src="https://github.com/user-attachments/assets/672b9bbf-dea9-41c0-9655-e88b89c111fe" />

<br>


## Step 3: Verify the Result
After deployment, access your website and check the response headers to confirm:

```bash
X-Frame-Options: DENY
Content-Security-Policy: frame-ancestors 'none'
```

**Verification Steps**:
    - Open browser developer tools (F12) → Go to the Network tab → Select the main HTML document → Check the Headers
    - Confirm that the above two headers are present in the response.

Or use the following iframe test page to check whether embedding is blocked:
```html
<!DOCTYPE html>
<html>
<head>
    <title>Clickjacking Test</title>
</head>
<body>
<h2>If you see the embedded site below, iframe protection is not working</h2>
<iframe
    src="https://op-geth.quarkchain.io/"
    width="800"
    height="600"
    style="opacity: 0.8;"
></iframe>
</body>
</html>
```
