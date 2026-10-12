#![allow(clippy::unused_async)]
use axum::http::StatusCode;
use loco_rs::prelude::*;

use crate::{
    dtos::{
        common::{ApiError, Page},
        posts::{CreatePost, PostDto, UpdatePost},
    },
    models::{
        _entities::posts::{ActiveModel, Column, Entity},
        posts::Model,
        users,
    },
};

/// Build a 404 response shaped as the [`ApiError`] envelope.
fn not_found(message: &str) -> Response {
    let error = ApiError {
        code: "not_found".to_string(),
        message: message.to_string(),
        details: None,
    };
    (StatusCode::NOT_FOUND, Json(error)).into_response()
}

/// A post the current user owns, or the response to send instead: 404 when
/// there is no such post, 403 when someone else owns it.
async fn owned_post(
    ctx: &AppContext,
    auth: &auth::JWT,
    id: i64,
) -> Result<std::result::Result<Model, Response>> {
    let Some(post) = Entity::find_by_id(id).one(&ctx.db).await? else {
        return Ok(Err(not_found("post not found")));
    };
    if !post.is_owned_by(&ctx.db, &auth.claims.pid).await {
        let error = ApiError {
            code: "forbidden".to_string(),
            message: "not your post".to_string(),
            details: None,
        };
        return Ok(Err((StatusCode::FORBIDDEN, Json(error)).into_response()));
    }
    Ok(Ok(post))
}

#[debug_handler]
async fn list(
    auth: auth::JWT,
    State(ctx): State<AppContext>,
    Query(pagination): Query<query::PaginationQuery>,
) -> Result<Json<Page<PostDto>>> {
    let user = users::Model::find_by_pid(&ctx.db, &auth.claims.pid).await?;
    let res = query::paginate(
        &ctx.db,
        Entity::find()
            .filter(Column::UserId.eq(user.id))
            .order_by_asc(Column::Id),
        None,
        &pagination,
    )
    .await?;

    Ok(Json(Page::from_query(res)))
}

#[debug_handler]
async fn get_one(
    auth: auth::JWT,
    State(ctx): State<AppContext>,
    Path(id): Path<i64>,
) -> Result<Response> {
    let model = match owned_post(&ctx, &auth, id).await? {
        Ok(post) => post,
        Err(response) => return Ok(response),
    };
    Ok(Json(PostDto::from(model)).into_response())
}

#[debug_handler]
async fn create(
    auth: auth::JWT,
    State(ctx): State<AppContext>,
    Json(params): Json<CreatePost>,
) -> Result<Response> {
    let owner = users::Model::find_by_pid(&ctx.db, &auth.claims.pid).await?;
    let item = ActiveModel {
        title: Set(params.title),
        user_id: Set(owner.id),
        ..Default::default()
    };
    let item = item.insert(&ctx.db).await?;

    Ok((StatusCode::CREATED, Json(PostDto::from(item))).into_response())
}

#[debug_handler]
async fn update(
    auth: auth::JWT,
    State(ctx): State<AppContext>,
    Path(id): Path<i64>,
    Json(params): Json<UpdatePost>,
) -> Result<Response> {
    let model = match owned_post(&ctx, &auth, id).await? {
        Ok(post) => post,
        Err(response) => return Ok(response),
    };

    let mut item = model.into_active_model();
    item.title = Set(params.title);
    let item = item.update(&ctx.db).await?;

    Ok(Json(PostDto::from(item)).into_response())
}

#[debug_handler]
async fn remove(
    auth: auth::JWT,
    State(ctx): State<AppContext>,
    Path(id): Path<i64>,
) -> Result<Response> {
    let model = match owned_post(&ctx, &auth, id).await? {
        Ok(post) => post,
        Err(response) => return Ok(response),
    };

    model.into_active_model().delete(&ctx.db).await?;

    Ok(StatusCode::NO_CONTENT.into_response())
}

pub fn routes() -> Routes {
    Routes::new()
        .prefix("/api/posts")
        .add("/", get(list))
        .add("/", post(create))
        .add("/{id}", get(get_one))
        .add("/{id}", put(update))
        .add("/{id}", delete(remove))
}
