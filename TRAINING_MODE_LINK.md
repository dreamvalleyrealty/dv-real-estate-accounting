# Main App Training Mode Link

The main navigation includes a permanent **Training Mode** item. It opens the separate training app in a new tab and never switches the main app's database.

After the DigitalOcean training app has been created, set this build-time environment variable in the main app's hosting settings:

`VITE_TRAINING_APP_URL=https://<your-training-app-domain>`

Use the actual DigitalOcean training app URL; do not use the Supabase project URL. If the variable is missing, the menu item remains visible and tells the user that the link has not been configured yet.

The training deployment must use only the training Supabase URL and public anon/publishable key. Do not put a service-role key in Vite variables.
