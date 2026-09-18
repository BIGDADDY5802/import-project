#!/bin/bash
# Use this for your user data (script from top to bottom)
# install httpd (Linux 2 version)
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd

# Variable for the URL
BASE_URL="http://169.254.169.254/latest"

# Get token for metadata requests
TOKEN=$(curl -X PUT "$BASE_URL/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 3600" -s)

# Collect instance info and save to variables
LOCAL_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s "$BASE_URL/meta-data/local-ipv4")
AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s "$BASE_URL/meta-data/placement/availability-zone")
HOST_NAME=$(hostname -f)

# Create simple webpage and save to /var/www/html/index.html
# EOF marks where the HTML starts and stops basically
cat << EOF > /var/www/html/index.html
<!doctype html>
<html lang=\"en\" class=\"h-100\">
<head>
<title>This webpage is owned by Jerome</title>
</head>
<body>
<div>
<h1>"I Jerome, Thank Theo And Jorge, For Teaching Me About Ec2s In Aws. One Step Closer To Escaping Keisha!</h1>

<h1>With This Class, I Will Net 350,000 Per Year!</h1>

<iframe src="https://giphy.com/embed/rtiV85E9f6ruM" width="444" height="480" style="" frameBorder="0" class="giphy-embed" allowFullScreen></iframe><p><a href="https://giphy.com/gifs/funny-other-rtiV85E9f6ruM">via GIPHY</a></p>

<h1>I like these too</h1>

<h1>I'm just used to some bounce back</h1>

<br>

<iframe src="https://giphy.com/embed/JOXHRcd3Llz5m" width="381" height="480" style="" frameBorder="0" class="giphy-embed" allowFullScreen></iframe><p><a href="https://giphy.com/gifs/girl-gym-provides-JOXHRcd3Llz5m">via GIPHY</a></p>
<br>
<h2>Instance Details</h2>
    <p><strong>Hostname:</strong> ${HOST_NAME}</p>
    <p><strong>Private IP:</strong> ${LOCAL_IP}</p>
    <p><strong>Availability Zone:</strong> ${AZ}</p>
</body>
</html>
EOF