---
title: Hello world
date: 2022-02-22 22:46:48
excerpt: 纪念第一篇 POST，关于 Hexo 和 Github Pages
tags: Blogs
---

## 首次部署

在 Github 网页创建一个新仓库，Github Pages 一定是 `github.io` 结尾的，创建之后在本地将这个仓库 `clone` 下来：

```shell
# Windows（在 D 盘创建 Blogs\ 目录，举个例子）
D:
cd Blogs\

# MacOS
cd /Users/Myname/Blogs

# Windows / MacOS
git clone https://github.com/username/username.github.io.git
```

环境用 `Docker` 部署，暴露端口 4000

```Dockerfile
FROM node:hydrogen-slim

ENV LC_ALL=zh_CN.UTF-8
ENV LANG=zh_CN.UTF-8
ENV LANGUAGE=zh_CN.UTF-8
ENV HEXO_SERVER_PORT=4000

RUN apt-get update && \
    apt-get install -yqq --no-install-recommends ca-certificates && \
    # 更新源
    cp /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.bak && \
    sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get clean && apt-get update && apt-get install -yqq --no-install-recommends \
        git git-lfs curl gpg vim net-tools lsof procps locales openssl openssh-client jq \
        yarn nasm wget dos2unix build-essential autoconf automake gettext libtool \
        pkg-config gettext libpng-dev gh zsh && \
    # 删除包管理器缓存以缩小镜像体积，参考 https://docs.docker.com/develop/develop-images/instructions/#run
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean && \
    yarn global add gulp && \
    npm config set registry https://registry.npmmirror.com && \
    npm install -g pm2 nrm npm-check && \
    npm install -g hexo-cli && \
    npm install -g cnpm --registry=https://registry.npmmirror.com && \
    apt-get clean && \
    yarn cache clean && \
    npm cache clean --force && \
    # mac 全局忽略 .DS_Store 配置文件
    # ref to: https://orianna-zzo.github.io/sci-tech/2018-01/mac%E4%B8%ADgit%E5%BF%BD%E7%95%A5.ds_store%E6%96%87%E4%BB%B6/
    echo "# Mac OS specified" > ~/.gitignore_global && \
    echo "**/.DS_Store" > ~/.gitignore_global && \
    git config --global core.excludesfile ~/.gitignore_global && \
    # 配置 zsh
    git clone https://github.com/ohmyzsh/ohmyzsh.git /root/.oh-my-zsh && \
    cp /root/.oh-my-zsh/templates/zshrc.zsh-template /root/.zshrc && \
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/plugins/zsh-syntax-highlighting && \
    git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/plugins/zsh-autosuggestions && \
    chsh -s $(which zsh) && \
    sed -i 's/^plugins=(git)$/plugins=(git wd zsh-syntax-highlighting zsh-autosuggestions)/' ~/.zshrc && \
    # 中文
    sed -i -e 's/# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales

WORKDIR /blogs
EXPOSE ${HEXO_SERVER_PORT}
CMD ["/usr/bin/zsh"]
```

通过：

```shell
docker buildx build --load -t hexo:latest .
```

创建镜像，然后：

```shell
# Windows
docker run -it -v D:\Blogs\username.github.io:/blogs -w /blogs -p 4000:4000 --name hexo hexo:latest /usr/bin/zsh

# MacOS / Linux
docker run -it -v /Users/Myname/Blogs/username.github.io:/blogs -w /blogs -p 4000:4000 --name hexo hexo:latest /usr/bin/zsh
```

创建容器，唯一要注意的是一定要将：

- 宿主电脑的博客目录（先创建）映射到容器（`/blogs`）里面
- 容器监听的端口映射到宿主电脑上

然后进入容器，在 `/blogs` 目录，这个仓库是空的，新建一个分支 `hexo`，安排如下：

- `master`：用来保存博客本身
- `hexo`：用来保存 Hexo 的静态部署

要注意的是：**这两个分支是完全不一样的，博客的内容（`Markdown` 写的东西）放在 `master`，`hexo` 分支不是我们自己主动更新的，是后面执行 `hexo d` 由 Hexo 自动推送的**，可以参考 [我的个人博客](https://github.com/horbyn/horbyn.github.io)。为了别让自己的博客被弄乱或丢失，`master` 分支的推送一定要很小心，建议通过其他形式额外备份

这样设置分支有一点很麻烦的是，当你从 `master` 切换到 `hexo` 分支，由于两个分支完全不一样，所以会有很多不一样的文件弄乱 git 工作区，处理起来很麻烦，解决办法是 **永远不要切换到 `hexo` 分支** &#128517;

回到 `/blogs` 目录，执行：

```shell
hexo init
```

让 Hexo 初始化目录，后面就可以更新博客了，下面是一些命令：

- 新增博客之后重新生成静态文件：`hexo generate` 或 `hexo g`
- 启动本地服务：`hexo server` 或 `hexo s`
- 部署到远端：`hexo deploy` 或 `hexo d`

一键 XX：

- 一键本地启动：`hexo clean && hexo g && hexo s`
- 一键部署：`hexo clean && hexo g && hexo d`

在部署 github 之前先设置好：

- [SSH 连接](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/checking-for-existing-ssh-keys)：通过 `ssh -T git@github.com` 验证，输出 `... successfully ...` 才成功
- [Token 验证](https://zhuanlan.zhihu.com/p/401978754)：输入 `git remote set-url origin https://<your_token>@github.com/<USERNAME>/<REPO>.git` 添加令牌至远程仓库
- 博客目录根目录下的 `_config.yml` 修改 `deploy` 字段，如下

```yml
deploy:
  type: git
  repo: git@github.com:username/username.github.io.git
  branch: hexo # 这里分支一定要写 hexo，不要写 master，否则会弄乱所有博客
```

每次更新博客之后通过 `push master` 来备份，下面表格给出了博客目录中什么东西是需要备份的，参考 [Hexo博客迁移步骤](https://wzw21.cn/2023/10/22/hexo-blog-migration/)：

目录 / 文件名|备份|备注
--|--|-----
`.deploy_git`|看情况|执行 `hexo d` 之后才会生成，如果不备份，即使你的博客内容是两三年前的，但以后你每次 `hexo d` 推送到 `hexo` 分支的提交记录都是全新的。但对你博客的创建时间没有影响，无非是每次部署都从第一个 commit 开始而已。如果你希望 `hexo` 分支保留 commit 记录就备份这个目录，否则可以不备份
`node_modules`|不用备份|`npm` 依赖
`public`|不用|`hexo g` 会重新生成
`scaffolds`|需要备份|貌似是 Hexo 的草稿存放目录，但我不用草稿功能所以不评价
`source`|需要|真正的博客数据存放目录，这个目录必须备份
`themes`|看情况|看你用的 Hexo 主题，根据主题开发者的建议来决定
`.gitignore`|需要|
`_config.yml`|需要|Hexo 配置文件
`db.json`|不用|`hexo g` 生成的
`package.json`|需要|保存了 Hexo 的管理信息
`package-lock.json`|需要|见参考文章，我是备份了的
`_config.<theme>.json`|看情况|看你用的 Hexo 主题，根据主题开发者的建议来决定
其他目录|看情况|我根据我使用的主题备份了一些图片，都丢到 git 仓库来备份了

## 恢复博客

这一章适用于：

- 有两台电脑：家里的电脑刚完成首次 Hexo 部署；现在另外一个电脑也要部署 Hexo 并将博客同步过来
- 只有一台电脑，但太旧已经换新了

直接将 `username/username.github.io` 仓库 `clone` 下来，切换 `master` 博客目录：

- 安装依赖：根据你使用的 Hexo 主题的 `README` 安装相应的依赖，如果依赖很多建议一开始就写个脚本记录下来
- 执行 `hexo g` 尝试生成 Hexo 项目（**因为这个时候已经不是空的 Hexo 项目了，所以不要执行 `hexo init` 了**）
- 执行 `hexo s` 尝试启动服务

如果像前一章那样处理，到这一步就恢复起来了，否则只能根据出错信息找原因了
