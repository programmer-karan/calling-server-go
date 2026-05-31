# 🚀 Deploying LiveKit to AWS (EC2)

To deploy this setup on AWS so you can make calls from anywhere (Pune to Mumbai), you need to deploy the **LiveKit Server** and your **Token Server** on an EC2 instance.

Here is the exact step-by-step guide.

## Step 1: Launch an EC2 Instance
1. Go to AWS Console -> EC2 -> **Launch Instance**
2. **OS**: Ubuntu 22.04 LTS
3. **Instance Type**: `t3.micro` (free tier) or `t3.small` (recommended for video)
4. **Network Settings**: Create a new Security Group and open the following ports:
   - `22 / TCP` (SSH)
   - `80 / TCP` (HTTP - for SSL/Let's Encrypt)
   - `443 / TCP` (HTTPS - required for WebRTC)
   - `7881 / TCP` (WebRTC fallback)
   - `7882 / UDP` (WebRTC signaling)
   - `50000 - 50100 / UDP` (WebRTC Audio/Video Media)
5. **Storage**: 15 GB gp3
6. Launch the instance and SSH into it.

## Step 2: Set up a Domain Name (Required)
WebRTC requires **HTTPS/SSL**, which means you need a domain name (e.g., `meet.yourdomain.com`).
1. Go to Route53 (or GoDaddy/Namecheap)
2. Create an `A Record` pointing `meet.yourdomain.com` to your EC2 instance's **Public IPv4 Address**.

## Step 3: Install Docker & LiveKit on EC2
Once connected to your EC2 instance via SSH, run the official LiveKit installer. It automatically sets up Docker, LiveKit, Caddy (for SSL), and Redis.

```bash
# 1. Download the LiveKit deployment script
curl -sSL https://get.livekit.io/cli | bash

# 2. Run the deployment generator
sudo livekit-cli generate-deployment
```

The generator will ask you a few questions:
- **Primary domain name**: `meet.yourdomain.com`
- **Turn domain**: (leave blank/skip)
- **Let's Encrypt Email**: `your-email@example.com`
- **Startup with Redis**: Yes
- **LiveKit API Key / Secret**: Let it generate random ones for you! **(Save these securely!)**

This will generate a `docker-compose.yaml` and a `livekit.yaml` file in your current directory.

```bash
# 3. Start LiveKit!
docker compose up -d
```

## Step 4: Deploy your Token Server
You need to run the `token-server` we built so your Flutter app can get JWT tokens.

```bash
# 1. Install Go on EC2
sudo snap install go --classic

# 2. Copy your token-server code to EC2 (or clone from GitHub)
git clone https://github.com/programmer-karan/calling-server-go.git
cd calling-server-go/livekit/token-server

# 3. Start the token server with your NEW keys from Step 3
export LIVEKIT_API_KEY="your-new-api-key"
export LIVEKIT_API_SECRET="your-new-api-secret"
export LIVEKIT_URL="https://meet.yourdomain.com"
go run main.go
```
*(In a real production environment, you would use `systemd` or Docker to keep this token server running in the background).*

## Step 5: Update Your Flutter App
Finally, point your Flutter app to your EC2 server!

```dart
Navigator.push(context, MaterialPageRoute(
  builder: (_) => LiveKitCallScreen(
    // Point this to your EC2 instance running the token server
    tokenServerUrl: 'http://YOUR_EC2_PUBLIC_IP:8080',  
    roomName: 'pune-to-mumbai',
    identity: 'Karan',
    // Point this to your secure LiveKit domain
    livekitUrl: 'wss://meet.yourdomain.com',
  ),
));
```

---
### 🎯 Why AWS requires this setup:
1. **Public IP**: AWS gives you a public IP that anyone on the internet can reach.
2. **HTTPS / SSL**: Browsers and mobile phones physically block camera and microphone access if the server does not have a valid SSL certificate (HTTPS). The LiveKit setup script handles this automatically using Caddy and Let's Encrypt.
3. **UDP Ports**: Video and audio travel over UDP. AWS Security Groups let you open the exact ports (50000-50100) needed for video data to flow from Pune to Mumbai without being blocked.
