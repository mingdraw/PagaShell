use super::{
    auth::{AuthHelper, AuthResult, SecurityType},
    connection::VncClient,
    security,
};
use std::future::Future;
use std::pin::Pin;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite};
use tracing::{info, trace};

use crate::{PixelFormat, VncEncoding, VncError, VncVersion};

pub enum VncState<S, F>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync + 'static,
    F: Future<Output = Result<String, VncError>> + Send + Sync + 'static,
{
    Handshake(VncConnector<S, F>),
    Authenticate(VncConnector<S, F>),
    Connected(VncClient),
}

impl<S, F> VncState<S, F>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync + 'static,
    F: Future<Output = Result<String, VncError>> + Send + Sync + 'static,
{
    pub fn try_start(
        self,
    ) -> Pin<Box<dyn Future<Output = Result<Self, VncError>> + Send + Sync + 'static>> {
        Box::pin(async move {
            match self {
                VncState::Handshake(mut connector) => {
                    // Read the rfbversion informed by the server
                    let (rfbversion, is_apple) =
                        VncVersion::read_with_apple_flag(&mut connector.stream).await?;
                    connector.is_apple_server = is_apple;
                    trace!(
                        "Our version {:?}, server version {:?}",
                        connector.rfb_version,
                        rfbversion
                    );
                    let rfbversion = if connector.rfb_version < rfbversion {
                        connector.rfb_version
                    } else {
                        rfbversion
                    };

                    // Record the negotiated rfbversion
                    connector.rfb_version = rfbversion;
                    trace!("Negotiated rfb version: {:?}", rfbversion);
                    rfbversion.write(&mut connector.stream).await?;
                    Ok(VncState::Authenticate(connector).try_start().await?)
                }
                VncState::Authenticate(mut connector) => {
                    let (security_types, saw_apple) =
                        SecurityType::read_offers(&mut connector.stream, &connector.rfb_version)
                            .await?;
                    connector.is_apple_server |= saw_apple;

                    if security_types.is_empty() {
                        return Err(VncError::UnsupportedSecurityType);
                    }

                    let username = connector.username.as_deref().map(str::trim).unwrap_or("");
                    let has_none = security_types.contains(&SecurityType::None);
                    let has_vnc = security_types.contains(&SecurityType::VncAuth);
                    let has_ard = security_types.contains(&SecurityType::AppleRemoteDesktop);

                    if has_none {
                        match connector.rfb_version {
                            VncVersion::RFB33 => {
                                // If the security-type is 1, for no authentication, the server does not
                                // send the SecurityResult message but proceeds directly to the
                                // initialization messages (Section 7.3).
                                info!("No auth needed in vnc3.3");
                            }
                            VncVersion::RFB37 => {
                                // After the security handshake, if the security-type is 1, for no
                                // authentication, the server does not send the SecurityResult message
                                // but proceeds directly to the initialization messages (Section 7.3).
                                info!("No auth needed in vnc3.7");
                                SecurityType::write(&SecurityType::None, &mut connector.stream)
                                    .await?;
                            }
                            VncVersion::RFB38 => {
                                info!("No auth needed in vnc3.8");
                                SecurityType::write(&SecurityType::None, &mut connector.stream)
                                    .await?;
                                let result = connector.stream.read_u32().await?.try_into()?;
                                if let AuthResult::Failed = result {
                                    let _ = crate::limits::string(
                                        &mut connector.stream,
                                        crate::limits::MAX_NAME,
                                    )
                                    .await;
                                    return Err(VncError::WrongPassword);
                                }
                            }
                        }
                    } else if !username.is_empty() && has_ard {
                        if connector.rfb_version != VncVersion::RFB33 {
                            SecurityType::write(
                                &SecurityType::AppleRemoteDesktop,
                                &mut connector.stream,
                            )
                            .await?;
                        }
                        if connector.auth_methond.is_none() {
                            return Err(VncError::NoPassword);
                        }
                        let credential = (connector.auth_methond.take().unwrap()).await?;
                        let result = security::ard::authenticate(
                            &mut connector.stream,
                            username,
                            &credential,
                        )
                        .await?;
                        if let AuthResult::Failed = result {
                            if connector.rfb_version == VncVersion::RFB38 {
                                // macOS Screen Sharing often closes immediately after SecurityResult=1
                                // without sending an RFB 3.8 reason string.
                                let _ = crate::limits::string(
                                    &mut connector.stream,
                                    crate::limits::MAX_NAME,
                                )
                                .await;
                            }
                            return Err(VncError::WrongPassword);
                        }
                    } else if has_vnc {
                        if connector.rfb_version != VncVersion::RFB33 {
                            SecurityType::write(&SecurityType::VncAuth, &mut connector.stream)
                                .await?;
                        }

                        // get password
                        if connector.auth_methond.is_none() {
                            return Err(VncError::NoPassword);
                        }

                        let credential = (connector.auth_methond.take().unwrap()).await?;

                        // auth
                        let auth = AuthHelper::read(&mut connector.stream, &credential).await?;
                        auth.write(&mut connector.stream).await?;
                        let result = auth.finish(&mut connector.stream).await?;
                        if let AuthResult::Failed = result {
                            if connector.rfb_version == VncVersion::RFB38 {
                                let _ = crate::limits::string(
                                    &mut connector.stream,
                                    crate::limits::MAX_NAME,
                                )
                                .await;
                            }
                            return Err(VncError::WrongPassword);
                        }
                    } else if has_ard {
                        return Err(VncError::UsernameRequired);
                    } else {
                        return Err(VncError::UnsupportedSecurityType);
                    }
                    info!("auth done, client connected");

                    Ok(VncState::Connected(
                        VncClient::new_with_options(
                            connector.stream,
                            connector.allow_shared,
                            connector.pixel_format,
                            connector.encodings,
                            connector.prefer_server_true_color_32,
                            connector.is_apple_server,
                            connector.emit_frame_complete,
                            connector.output_channel_capacity,
                        )
                        .await?,
                    ))
                }
                _ => unreachable!(),
            }
        })
    }

    pub fn finish(self) -> Result<VncClient, VncError> {
        if let VncState::Connected(client) = self {
            Ok(client)
        } else {
            Err(VncError::ConnectError)
        }
    }
}

/// Connection Builder to setup a vnc client
pub struct VncConnector<S, F>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    F: Future<Output = Result<String, VncError>> + Send + Sync + 'static,
{
    stream: S,
    auth_methond: Option<F>,
    username: Option<String>,
    rfb_version: VncVersion,
    allow_shared: bool,
    pixel_format: Option<PixelFormat>,
    prefer_server_true_color_32: bool,
    is_apple_server: bool,
    emit_frame_complete: bool,
    output_channel_capacity: Option<usize>,
    encodings: Vec<VncEncoding>,
}

impl<S, F> VncConnector<S, F>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + Sync + 'static,
    F: Future<Output = Result<String, VncError>> + Send + Sync + 'static,
{
    /// To new a vnc client configuration with stream `S`
    ///
    /// `S` should implement async I/O methods
    ///
    /// ```no_run
    /// use vnc::{PixelFormat, VncConnector, VncError};
    /// use tokio::{self, net::TcpStream};
    ///
    /// #[tokio::main]
    /// async fn main() -> Result<(), VncError> {
    ///     let tcp = TcpStream::connect("127.0.0.1:5900").await?;
    ///     let vnc = VncConnector::new(tcp)
    ///         .set_auth_method(async move { Ok("password".to_string()) })
    ///         .add_encoding(vnc::VncEncoding::Tight)
    ///         .add_encoding(vnc::VncEncoding::Zrle)
    ///         .add_encoding(vnc::VncEncoding::CopyRect)
    ///         .add_encoding(vnc::VncEncoding::Raw)
    ///         .allow_shared(true)
    ///         .set_pixel_format(PixelFormat::bgra())
    ///         .build()?
    ///         .try_start()
    ///         .await?
    ///         .finish()?;
    ///     Ok(())
    /// }
    /// ```
    ///
    pub fn new(stream: S) -> Self {
        Self {
            stream,
            auth_methond: None,
            username: None,
            allow_shared: true,
            rfb_version: VncVersion::RFB38,
            pixel_format: None,
            prefer_server_true_color_32: false,
            is_apple_server: false,
            emit_frame_complete: false,
            output_channel_capacity: None,
            encodings: Vec::new(),
        }
    }

    /// Optional username for Apple Remote Desktop (Security Type 30) authentication.
    pub fn set_username(mut self, username: String) -> Self {
        self.username = if username.trim().is_empty() {
            None
        } else {
            Some(username)
        };
        self
    }

    /// Keep the server's native 32-bit 8-8-8 true-color pixel format instead of sending
    /// `SetPixelFormat`, which avoids conversion overhead and quirks on macOS Screen Sharing.
    pub fn prefer_server_true_color_32(mut self, prefer: bool) -> Self {
        self.prefer_server_true_color_32 = prefer;
        self
    }

    /// Emit [crate::VncEvent::FrameComplete] after each server FramebufferUpdate message.
    pub fn emit_frame_complete(mut self, emit: bool) -> Self {
        self.emit_frame_complete = emit;
        self
    }

    /// Override the decoder event channel capacity (clamped to at least 2).
    pub fn output_channel_capacity(mut self, capacity: usize) -> Self {
        self.output_channel_capacity = Some(capacity.max(2));
        self
    }

    /// An async callback which is used to query credentials if the vnc server has set
    ///
    /// ```no_compile
    /// connector = connector.set_auth_method(async move { Ok("password".to_string()) })
    /// ```
    ///
    /// if you're building a wasm app,
    /// the async callback also allows you to combine it to a promise
    ///
    /// ```no_compile
    /// #[wasm_bindgen]
    /// extern "C" {
    ///     fn get_password() -> js_sys::Promise;
    /// }
    ///
    /// connector = connector
    ///        .set_auth_method(async move {
    ///            let auth = JsFuture::from(get_password()).await.unwrap();
    ///            Ok(auth.as_string().unwrap())
    ///     });
    /// ```
    ///
    /// While in the js code
    ///
    ///
    /// ```javascript
    /// var password = '';
    /// function get_password() {
    ///     return new Promise((reslove, reject) => {
    ///        document.getElementById("submit_password").addEventListener("click", () => {
    ///             password = window.document.getElementById("input_password").value
    ///             reslove(password)
    ///         })
    ///     });
    /// }
    /// ```
    ///
    /// The future won't be polled if the sever doesn't apply any password protections to the session
    ///
    pub fn set_auth_method(mut self, auth_callback: F) -> Self {
        self.auth_methond = Some(auth_callback);
        self
    }

    /// The max vnc version that we supported
    ///
    /// Version should be one of the [VncVersion]
    ///
    pub fn set_version(mut self, version: VncVersion) -> Self {
        self.rfb_version = version;
        self
    }

    /// Set the rgb order which you will use to resolve the image data
    ///
    /// In most of the case, use `PixelFormat::bgra()` on little endian PCs
    ///
    /// And use `PixelFormat::rgba()` on wasm apps (with canvas)
    ///
    /// Also, customized format is allowed
    ///
    /// Will use the default format informed by the vnc server if not set
    ///
    /// In this condition, the client will get a [crate::VncEvent::SetPixelFormat] event notified
    ///
    pub fn set_pixel_format(mut self, pf: PixelFormat) -> Self {
        self.pixel_format = Some(pf);
        self
    }

    /// Shared-flag is non-zero (true) if the server should try to share the
    ///
    /// desktop by leaving other clients connected, and zero (false) if it
    ///
    /// should give exclusive access to this client by disconnecting all
    ///
    /// other clients.
    ///
    pub fn allow_shared(mut self, allow_shared: bool) -> Self {
        self.allow_shared = allow_shared;
        self
    }

    /// Client encodings that we want to use
    ///
    /// One of [VncEncoding]
    ///
    /// [VncEncoding::Raw] must be sent as the RFC required
    ///
    /// The order to add encodings is the order to inform the server
    ///
    pub fn add_encoding(mut self, encoding: VncEncoding) -> Self {
        self.encodings.push(encoding);
        self
    }

    /// Complete the client configuration
    ///
    pub fn build(self) -> Result<VncState<S, F>, VncError> {
        if self.encodings.is_empty() {
            return Err(VncError::NoEncoding);
        }
        if let Some(format) = &self.pixel_format {
            format.validate()?;
        }
        Ok(VncState::Handshake(self))
    }
}
